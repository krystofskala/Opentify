"""Rozbor zvuku z 30s ukázky Deezeru -- pro skladby, které ještě nejsou
stažené (nové v Pusť teď, objevy). Bez něj by řazení podle plynulosti a
nálady zvuku nové skladby nevidělo (dostaly by průměr).

- Ukázka se jen stáhne do paměti, dekóduje a zahodí (nic se neukládá).
- Výsledek jde do `TrackFeatures` s `version = 0`: až se stáhne celý
  soubor, rozbor z něj ho přepíše (`loudness._pending_ids` bere starší verze).
- Ukázka je kus ze středu skladby, takže začátek/konec = energie ukázky a
  hlasitost okrajů se nevyplňuje (nevíme).
"""

from __future__ import annotations

import asyncio
import logging
import subprocess

import httpx
from sqlmodel import Session, select

from app.db import engine

logger = logging.getLogger(__name__)

PREVIEW_VERSION = 0
_TIMEOUT_S = 15
_sem = asyncio.Semaphore(3)
_background: set[asyncio.Task] = set()  # co nestihne limit, doběhne na pozadí


def _decode(data: bytes) -> bytes | None:
    from app.audio_features import SR

    try:
        proc = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostats", "-loglevel", "error", "-i", "pipe:0",
             "-vn", "-ac", "1", "-ar", str(SR), "-f", "s16le", "pipe:1"],
            input=data, capture_output=True, timeout=_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return proc.stdout if proc.returncode == 0 and proc.stdout else None


def _store(recording_id: str, features: dict) -> None:
    from app.models import TrackFeatures
    from app.utils import utcnow

    with Session(engine) as session:
        row = session.get(TrackFeatures, recording_id)
        if row is not None and row.version > PREVIEW_VERSION:
            return  # mezitím rozbor z celého souboru -- ten má přednost
        row = row or TrackFeatures(recording_id=recording_id)
        row.energy = features.get("energy")
        row.intro_energy = row.outro_energy = features.get("energy")
        row.intro_level_db = row.outro_level_db = None
        row.bpm = features.get("bpm")
        row.bpm_confidence = features.get("bpm_confidence")
        row.flatness = features.get("flatness")
        row.high_ratio = features.get("high_ratio")
        row.centroid_hz = features.get("centroid_hz")
        row.version = PREVIEW_VERSION
        row.updated_at = utcnow()
        session.add(row)
        session.commit()


async def analyze(recording_id: str, deezer_id: str) -> bool:
    from app import audio_features
    from app.catalog.deezer import get_deezer_client

    async with _sem:
        try:
            track = await get_deezer_client().track(str(deezer_id))
            url = (track or {}).get("preview")
            if not url:
                return False
            async with httpx.AsyncClient(timeout=_TIMEOUT_S, follow_redirects=True) as client:
                resp = await client.get(url)
                resp.raise_for_status()
            pcm = await asyncio.to_thread(_decode, resp.content)
            features = await asyncio.to_thread(audio_features.compute, pcm) if pcm else None
        except Exception as exc:  # noqa: BLE001 -- doplněk, nesmí nic shodit
            logger.info("ukázka %s: %s", recording_id[:8], exc)
            return False
    if not features:
        return False
    await asyncio.to_thread(_store, recording_id, features)
    return True


def _missing(recording_ids: list[str]) -> list[tuple[str, str]]:
    from app.models import Recording, TrackFeatures

    with Session(engine) as session:
        have = set(
            session.exec(select(TrackFeatures.recording_id).where(TrackFeatures.recording_id.in_(recording_ids))).all()  # type: ignore[attr-defined]
        )
        rows = session.exec(
            select(Recording.id, Recording.deezer_id).where(Recording.id.in_([r for r in recording_ids if r not in have]))  # type: ignore[attr-defined]
        ).all()
    return [(rid, dz) for rid, dz in rows if dz and not str(dz).startswith("own:")]


async def ensure(recording_ids: list[str], timeout_s: float = 4.0) -> int:
    """Rozebrat ukázky skladeb bez rozboru; čeká nejvýš `timeout_s` (co
    nestihne, doběhne na pozadí a pomůže příští várce). Vrací počet hotových."""
    todo = await asyncio.to_thread(_missing, list(dict.fromkeys(recording_ids)))
    if not todo:
        return 0
    tasks = [asyncio.ensure_future(analyze(rid, dz)) for rid, dz in todo]
    for t in tasks:
        _background.add(t)
        t.add_done_callback(_background.discard)
    done, _pending = await asyncio.wait(tasks, timeout=timeout_s)
    return sum(1 for t in done if not t.cancelled() and t.exception() is None and t.result())
