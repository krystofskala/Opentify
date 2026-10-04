"""REST routy pro provisioning flow — implementace `/tracks/{id}/provision`,
`/jobs/{id}` a `/tracks/{id}/stream` z docs/openapi.yaml."""

from __future__ import annotations

import asyncio
import hashlib
import os
import time
from pathlib import Path
from typing import AsyncIterator, BinaryIO

from fastapi import APIRouter, Body, Depends, Header, HTTPException, Response
from fastapi.responses import FileResponse, JSONResponse, StreamingResponse
from pydantic import BaseModel
from sqlmodel import Session

from app.auth import get_current_user
from app.db import engine, get_session
from app.loudness import WAVEFORM_BUCKETS, decode_waveform, gain_for_client
from app.models import MediaAsset, MediaAssetStatus, ProvisioningJob
from app.provisioning_service import enqueue, escalate, get_or_create_job, stream_url_for

tracks_router = APIRouter(prefix="/tracks", tags=["provisioning"])
jobs_router = APIRouter(prefix="/jobs", tags=["provisioning"])

# `mimetypes.guess_type` v defaultní registraci nezná `.flac`/`.opus` na
# všech platformách -- explicitní mapa je jistější než spoléhat na to, co
# se zrovna nahodí v systémovém `/etc/mime.types` uvnitř kontejneru.
_MEDIA_TYPES = {
    ".flac": "audio/flac",
    ".mp3": "audio/mpeg",
    ".m4a": "audio/mp4",
    ".ogg": "audio/ogg",
    ".opus": "audio/opus",
    ".wav": "audio/wav",
}


class ProvisionRequest(BaseModel):
    # "interactive" = uživatel právě zmáčkl Přehrát a čeká -> prioritní fronta
    # + závod slskd vs. YouTube (viz worker). Bez těla (prefetch, starší
    # klienti) = běžná fronta, kvalita má přednost před rychlostí.
    priority: str | None = None


def _job_out(job: ProvisioningJob) -> dict:
    """camelCase jako zbytek API (docs/openapi.yaml `ProvisioningJob`) --
    dřív šel ven syrový SQLModel dump se snake_case klíči a klient
    (`ProvisioningJobModel.fromJson` čte `recordingId`) na tom spadl, takže
    každé nové stažení se v appce hned ukázalo jako selhané, bez průběhu a
    bez automatického přehrání po dokončení (živě nahlášeno)."""
    return {
        "id": job.id,
        "recordingId": job.recording_id,
        "status": job.status.value if hasattr(job.status, "value") else str(job.status),
        "attempts": job.attempts,
        "maxAttempts": job.max_attempts,
        "errorMessage": job.error_message,
        "createdAt": job.created_at.isoformat() if job.created_at else None,
        "startedAt": job.started_at.isoformat() if job.started_at else None,
        "finishedAt": job.finished_at.isoformat() if job.finished_at else None,
    }


@tracks_router.post("/{recording_id}/provision")
async def provision_track(
    recording_id: str,
    response: Response,
    body: ProvisionRequest | None = Body(default=None),
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, device_id = current
    interactive = body is not None and body.priority == "interactive"
    try:
        asset, job, created = get_or_create_job(session, recording_id, user_id, device_id)
    except LookupError:
        raise HTTPException(status_code=404, detail="recording nenalezen v katalogu")

    if job is None:
        # MediaAsset už AVAILABLE -> žádný job, rovnou stream (HTTP 200)
        response.status_code = 200
        return {
            "recordingId": recording_id,
            "status": asset.status.value,
            "streamUrl": stream_url_for(recording_id),
            "job": None,
            "loudnessGainDb": gain_for_client(asset.loudness_gain_db),
            "waveform": decode_waveform(asset.waveform),
        }

    if created:
        # Nově založený job -> publikuj na frontu. Při opakovaném volání
        # (created == False, job už PENDING/RUNNING) se nic nepublikuje
        # znovu — to je jádro idempotence tohoto endpointu.
        await enqueue(job, interactive=interactive)
    elif interactive:
        # Job už existuje (prefetch) -- ať ho uživatelův klik předběhne/zrychlí.
        await escalate(job)
    if not created and job.requested_by_user_id != user_id:
        from app.events import watch

        await watch(job.id, recording_id, user_id)

    response.status_code = 202
    return {
        "recordingId": recording_id,
        "status": asset.status.value,
        "streamUrl": None,
        "job": _job_out(job),
        "loudnessGainDb": None,
    }


@tracks_router.get("/{recording_id}/loudness")
def track_loudness(recording_id: str, session: Session = Depends(get_session)):
    """Korekce hlasitosti (dB) pro normalizaci na klientovi -- samostatně od
    `/provision`, protože u čerstvě obstarané skladby se měří až PO
    `track.available` (worker nechce zdržovat start přehrávání analýzou),
    takže ji klient dotáhne dodatečně. `null` = ještě neměřeno / nelze
    změřit."""
    asset = session.get(MediaAsset, recording_id)
    return {
        "recordingId": recording_id,
        "loudnessGainDb": gain_for_client(asset.loudness_gain_db) if asset else None,
    }


@tracks_router.get("/{recording_id}/waveform")
def track_waveform(
    recording_id: str,
    if_none_match: str | None = Header(default=None),
    session: Session = Depends(get_session),
):
    """Obrys hlasitosti skladby pro vlnovku v přehrávači: `buckets` =
    `bucketCount` hodnot 0..255 (vnímaná hlasitost stejně dlouhých úseků od
    začátku do konce skladby), `durationMs` = délka změřeného souboru. 404,
    dokud se neměřilo (počítá se hned po obstarání a na pozadí) nebo když
    soubor změřit nejde -- klient pak kreslí obyčejnou vlnovku."""
    asset = session.get(MediaAsset, recording_id)
    buckets = decode_waveform(asset.waveform) if asset else None
    if not buckets:
        raise HTTPException(status_code=404, detail="obrys hlasitosti zatím není spočítaný")
    etag = '"' + hashlib.sha1(asset.waveform.encode()).hexdigest()[:16] + '"'
    headers = {"ETag": etag, "Cache-Control": "public, max-age=86400"}
    if if_none_match == etag:
        return Response(status_code=304, headers=headers)
    return JSONResponse(
        {
            "recordingId": recording_id,
            "bucketCount": WAVEFORM_BUCKETS,
            "buckets": buckets,
            "durationMs": asset.waveform_duration_ms,
        },
        headers=headers,
    )


@jobs_router.get("/{job_id}")
def get_job(job_id: str, session: Session = Depends(get_session)):
    job = session.get(ProvisioningJob, job_id)
    if job is None:
        raise HTTPException(status_code=404, detail="job nenalezen")
    return _job_out(job)


# Bezpečnostní pojistka pro `_tail_growing_file`: pokud soubor přestane růst
# a stav se v DB nezmění na AVAILABLE/FAILED déle než tohle, stream se sám
# ukončí -- jinak by uvízlý/spadlý worker nechal HTTP request viset navěky.
_TAIL_MAX_IDLE_S = 30.0
_TAIL_POLL_INTERVAL_S = 0.25


@tracks_router.get("/{recording_id}/stream")
async def stream_track(recording_id: str, session: Session = Depends(get_session)):
    asset = session.get(MediaAsset, recording_id)
    if asset is None or not asset.storage_path:
        raise HTTPException(
            status_code=409,
            detail="skladba zatím není k dispozici, zavolej nejdřív POST /provision",
        )
    path = Path(asset.storage_path)
    media_type = _MEDIA_TYPES.get(path.suffix.lower())

    if asset.status == MediaAssetStatus.AVAILABLE:
        if not path.exists():
            raise HTTPException(status_code=409, detail="soubor chybí na disku i přes AVAILABLE stav")
        return FileResponse(path, media_type=media_type)

    if asset.status == MediaAssetStatus.DOWNLOADING:
        # Progresivní stream ještě rostoucího souboru -- viz `OnFileLocated`
        # v app/providers.py (jen `SlskdProvider` ho posílá dřív, než job
        # doběhne). Soubor v tuhle chvíli nemusí existovat ještě ani s
        # nulovými bajty (worker mezitím zapisuje do DB), proto vlastní
        # kontrola místo spoléhání na `FileResponse`.
        if not await asyncio.to_thread(path.exists):
            raise HTTPException(
                status_code=409, detail="stahování ještě nezačalo zapisovat soubor, zkus to za chvíli"
            )
        return StreamingResponse(
            _tail_growing_file(recording_id, path),
            media_type=media_type or "application/octet-stream",
        )

    raise HTTPException(
        status_code=409,
        detail="skladba zatím není k dispozici, zavolej nejdřív POST /provision",
    )


def _current_asset_status(recording_id: str) -> MediaAssetStatus | None:
    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        return asset.status if asset else None


def _read_from(f: BinaryIO, offset: int, length: int) -> bytes:
    f.seek(offset)
    return f.read(length)


async def _tail_growing_file(recording_id: str, path: Path) -> AsyncIterator[bytes]:
    """Servíruje soubor, co se pod ním pořád ještě zvětšuje -- otevře ho
    JEDNOU a dál čte přes stejný file handle (`os.fstat`, ne `path.stat()`),
    protože `SlskdProvider.fetch()` na konci přesune hotový soubor jinam
    (`shutil.move` mezi Docker volumes = kopie + smazání zdroje). Otevřený
    handle zůstává čitelný přes POSIX inode i po smazání/přejmenování
    zdrojové cesty, takže tenhle přesun stream nepřeruší -- klíčové pro
    korektnost, ne jen optimalizace.
    """
    f = await asyncio.to_thread(open, path, "rb")
    try:
        position = 0
        idle_since: float | None = None
        while True:
            size = await asyncio.to_thread(lambda: os.fstat(f.fileno()).st_size)
            if size > position:
                chunk = await asyncio.to_thread(_read_from, f, position, size - position)
                position = size
                idle_since = None
                if chunk:
                    yield chunk
                continue

            status = await asyncio.to_thread(_current_asset_status, recording_id)
            if status in (MediaAssetStatus.AVAILABLE, MediaAssetStatus.FAILED, None):
                # AVAILABLE: soubor je definitivně hotový (přesun proběhl AŽ
                # po "Completed, Succeeded", takže `size` výš už je finální).
                # FAILED/None: stahování selhalo/job zmizel -- ukončit stream,
                # klient uvidí jen useknuté přehrávání, ne chybu appky.
                return

            now = time.monotonic()
            if idle_since is None:
                idle_since = now
            elif now - idle_since > _TAIL_MAX_IDLE_S:
                return
            await asyncio.sleep(_TAIL_POLL_INTERVAL_S)
    finally:
        await asyncio.to_thread(f.close)
