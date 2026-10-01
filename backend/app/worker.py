"""Acquisition worker — konzumuje ProvisioningJob frontu z Redis Streams
a pohání stavový automat: PENDING -> RUNNING -> AVAILABLE | FAILED.

Proč čisté asyncio + Redis Streams a ne Celery: jediná externí závislost,
kterou stejně potřebujeme (Redis, kvůli pub/sub do WS vrstvy), a Streams
s consumer groups dávají at-least-once delivery, ACK a crash recovery
(XAUTOCLAIM) bez dalšího message brokeru. Horizontální škálování je
`docker compose up --scale worker=N` — každý proces má vlastní
CONSUMER_NAME, takže si zprávy nekonkurují.

Dvě fronty: `PROVISIONING_PRIORITY_STREAM` (uživatel právě zmáčkl Přehrát)
se čte vždy přednostně a má vlastní kapacitu, běžná fronta (prefetch alba)
nikdy nezabere všechny sloty. Každý worker zpracovává víc jobů souběžně
(stahování je síťově vázané), každý job drží Redis zámek obnovovaný
heartbeatem -- bez něj XAUTOCLAIM po 60 s předal ještě běžící job druhému
workeru a oba stahovaly stejný soubor (živě pozorováno: druhý soubor
odsunul, první pak spadl na "soubor nenalezen").

DB operace jsou schválně sync (SQLModel/SQLite) a volané přes
`asyncio.to_thread`, aby neblokovaly event loop, ve kterém běží zbytek
smyčky (čekání na Redis, publikování eventů).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import socket
import time
from pathlib import Path

from datetime import timedelta

from sqlmodel import Session, select

from app.db import engine, init_db
from app.events import publish_job_progress, publish_track_available, publish_track_streaming
from app.loudness import analyze_and_store
from app.models import (
    Artist,
    MediaAsset,
    MediaAssetStatus,
    ProvisioningJob,
    ProvisioningJobStatus,
    Recording,
)
from app.providers import (
    CompositeProvider,
    FetchResult,
    SlskdProvider,
    TrackMetadata,
    YoutubeProvider,
    build_provider,
)
from app.redis_bus import (
    PROVISIONING_GROUP,
    PROVISIONING_PRIORITY_STREAM,
    PROVISIONING_STREAM,
    get_redis,
    job_escalate_key,
    job_lock_key,
)
from app.utils import sha256_file, utcnow

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger("vault.worker")

MEDIA_ROOT = Path(os.environ.get("MEDIA_ROOT", "/data/media"))
CONSUMER_NAME = f"worker-{socket.gethostname()}-{os.getpid()}"
CLAIM_IDLE_MS = 60_000  # zprávy visící > 60s u mrtvého konzumenta se přeberou
BLOCK_MS = 1_000
LOCK_TTL_S = 90
HEARTBEAT_S = 20
MAX_INTERACTIVE_JOBS = int(os.environ.get("WORKER_MAX_INTERACTIVE_JOBS", "4"))
MAX_BACKGROUND_JOBS = int(os.environ.get("WORKER_MAX_BACKGROUND_JOBS", "2"))
# Když v závodě vyhraje YouTube, slskd stahuje dál a lepší (FLAC/320) soubor
# se prohodí až po téhle prodlevě -- ne hned, protože <audio> během
# přehrávání dělá range requesty na stejnou URL a prohození souboru uprostřed
# skladby by mu podstrčilo bajty z jiného souboru.
UPGRADE_DELAY_S = int(os.environ.get("PROVISIONING_UPGRADE_DELAY_S", "900"))
UPGRADES_ZSET = "vault:provisioning:upgrades"

provider = build_provider()
# Závod slskd vs. YouTube (a jejich samostatné řízení) jen pro výchozí
# `composite` -- ostatní MEDIA_PROVIDER režimy jedou po staru přes `provider`.
_slskd: SlskdProvider | None = None
_youtube: YoutubeProvider | None = None
if isinstance(provider, CompositeProvider):
    for _p in provider.providers:
        if isinstance(_p, SlskdProvider):
            _slskd = _p
        elif isinstance(_p, YoutubeProvider):
            _youtube = _p

# Silné reference na běžící analýzy -- `asyncio.create_task` drží na úlohu jen
# slabý odkaz a nedoběhnutá úloha by jinak mohla být uprostřed sesbírána GC.
_loudness_tasks: set[asyncio.Task] = set()


def _schedule_loudness(recording_id: str) -> None:
    async def run() -> None:
        try:
            gain = await asyncio.to_thread(analyze_and_store, recording_id)
            logger.info("analýza %s: korekce %s dB + obrys hlasitosti", recording_id, gain)
        except Exception:  # noqa: BLE001 - normalizace je jen bonus, nikdy nesmí shodit worker
            logger.exception("loudness analýza %s selhala", recording_id)

    task = asyncio.create_task(run())
    _loudness_tasks.add(task)
    task.add_done_callback(_loudness_tasks.discard)


def _schedule_download_check(recording_id: str) -> None:
    """Délka souboru vs katalog, podezřelé ještě přes Shazam (viz
    app/library/download_check.py). Fire-and-forget jako loudness."""
    from app.library.download_check import check_after_download

    task = asyncio.create_task(check_after_download(recording_id))
    _loudness_tasks.add(task)
    task.add_done_callback(_loudness_tasks.discard)


# ---------------------------------------------------------------------
# Sync DB pomocníci (volané přes asyncio.to_thread)
# ---------------------------------------------------------------------


def _start_job(job_id: str) -> dict | None:
    with Session(engine) as session:
        job = session.get(ProvisioningJob, job_id)
        if job is None:
            return None
        if job.status in (
            ProvisioningJobStatus.SUCCEEDED,
            ProvisioningJobStatus.CANCELLED,
            # FAILED job se znovu zkouší jen přes retry (ten ho vrátí na
            # PENDING) -- zpráva pro FAILED job je duplicita (priorita/eskalace).
            ProvisioningJobStatus.FAILED,
        ):
            return {"skip": True}

        asset = session.get(MediaAsset, job.recording_id)
        recording = session.get(Recording, job.recording_id)
        artist = (
            session.get(Artist, recording.artist_id)
            if recording and recording.artist_id
            else None
        )

        job.status = ProvisioningJobStatus.RUNNING
        job.attempts += 1
        job.started_at = utcnow()
        asset.status = MediaAssetStatus.DOWNLOADING
        session.add(job)
        session.add(asset)
        session.commit()

        return {
            "skip": False,
            "user_id": job.requested_by_user_id,
            "recording_id": job.recording_id,
            "recording_title": recording.title if recording else "",
            "recording_mbid": recording.mbid if recording else None,
            "recording_duration_ms": recording.duration_ms if recording else None,
            "artist_name": artist.name if artist else None,
            "album_title": _album_title(session, recording),
            "preferred_source": (recording.external_refs or {}).get("preferredSource") if recording else None,
            # "Stáhnout znovu" z kontroly Shazamem: přeskočit dřívější výběr.
            "skip_candidates": int((recording.external_refs or {}).get("youtubeSkip", 0)) if recording else 0,
            "rejected_sources": list((recording.external_refs or {}).get("rejectedSources") or []) if recording else [],
            "youtube_id": (recording.external_refs or {}).get("youtubeId") if recording else None,
            "attempts": job.attempts,
            "max_attempts": job.max_attempts,
        }


def _mark_downloading_path(recording_id: str, path: str) -> None:
    """Zapíše `storage_path` OKAMŽITĚ, jakmile provider soubor lokalizuje --
    ještě uprostřed stahování, status zůstává `DOWNLOADING`. Bez tohohle by
    `GET /stream` neměl odkud číst pro progresivní přehrávání (viz
    `OnFileLocated` v app/providers.py)."""
    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        if asset is None:
            return
        asset.storage_path = path
        asset.updated_at = utcnow()
        session.add(asset)
        session.commit()


_TERMINAL_JOB_STATUSES = (
    ProvisioningJobStatus.SUCCEEDED,
    ProvisioningJobStatus.FAILED,
    ProvisioningJobStatus.CANCELLED,
)


def _finish_success(
    job_id: str,
    storage_path: str,
    checksum: str,
    size: int,
    source_provider: str,
    audio_format: str | None,
    bitrate_kbps: int | None,
) -> str | None:
    with Session(engine) as session:
        job = session.get(ProvisioningJob, job_id)
        if job.status in _TERMINAL_JOB_STATUSES:
            # Duplicitní doručení stejné zprávy z Redis Streams (at-least-once
            # -- typicky po restartu workeru uprostřed zpracování, viz
            # `reclaim_stale`/XAUTOCLAIM) -- tenhle job už doběhl jinam dřív,
            # `None` říká volajícímu ať nic dál nepublikuje/nepřepisuje.
            return None
        asset = session.get(MediaAsset, job.recording_id)

        job.status = ProvisioningJobStatus.SUCCEEDED
        job.finished_at = utcnow()

        asset.status = MediaAssetStatus.AVAILABLE
        asset.storage_path = storage_path
        asset.checksum_sha256 = checksum
        asset.filesize_bytes = size
        asset.source_provider = source_provider
        asset.format = audio_format
        asset.bitrate_kbps = bitrate_kbps
        asset.loudness_gain_db = None  # nový soubor -> stará korekce už neplatí
        asset.waveform = None  # ...stejně tak obrys hlasitosti
        asset.waveform_duration_ms = None
        asset.last_error = None
        asset.updated_at = utcnow()

        session.add(job)
        session.add(asset)
        session.commit()
        return f"/api/v1/tracks/{job.recording_id}/stream"


def _finish_failure(job_id: str, error_message: str, attempts: int, max_attempts: int) -> bool | None:
    """Vrátí `True` = job se má zopakovat (zpět na PENDING + requeue),
    `False` = definitivně FAILED (attempts vyčerpány), `None` = duplicitní
    doběhnutí už jednou uzavřeného jobu -- volající nesmí publikovat žádný
    `job.progress`/requeue, jinak by pozdní duplicita přepsala novější stav
    v klientovi (viz `_TERMINAL_JOB_STATUSES` v `_finish_success`)."""
    with Session(engine) as session:
        job = session.get(ProvisioningJob, job_id)
        if job.status in _TERMINAL_JOB_STATUSES:
            return None
        asset = session.get(MediaAsset, job.recording_id)

        job.error_message = error_message[:2000]
        job.finished_at = utcnow()

        # `storage_path` mohl ukazovat na rozdělaný soubor ve slskd downloads
        # (viz `_mark_downloading_path`/progresivní stream) -- po selhání už
        # nic nezaručuje, že tam pořád je (slskd si ho může sám uklidit), tak
        # ať tam nezůstane viset mrtvý odkaz.
        asset.storage_path = None
        if attempts < max_attempts:
            job.status = ProvisioningJobStatus.PENDING
            asset.status = MediaAssetStatus.QUEUED
            retry = True
        else:
            job.status = ProvisioningJobStatus.FAILED
            asset.status = MediaAssetStatus.FAILED
            asset.last_error = error_message[:2000]
            retry = False

        session.add(job)
        session.add(asset)
        session.commit()
        return retry


def _apply_upgrade(recording_id: str, new_path: str, replaces: str, source: str, audio_format: str, bitrate: int | None) -> bool:
    """Prohodí YouTube soubor za lepší ze slskd -- jen pokud asset pořád
    ukazuje na ten YouTube soubor (mezitím mohl proběhnout nový provisioning
    apod.). Starý soubor se maže až po úspěšném zápisu do DB."""
    new = Path(new_path)
    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        if (
            asset is None
            or asset.status != MediaAssetStatus.AVAILABLE
            or asset.storage_path != replaces
            or not new.exists()
        ):
            if new.exists() and (asset is None or asset.storage_path != new_path):
                new.unlink(missing_ok=True)
            return False
        asset.storage_path = new_path
        asset.checksum_sha256 = sha256_file(new)
        asset.filesize_bytes = new.stat().st_size
        asset.source_provider = source
        asset.format = audio_format
        asset.bitrate_kbps = bitrate
        asset.loudness_gain_db = None
        asset.waveform = None
        asset.waveform_duration_ms = None
        asset.updated_at = utcnow()
        session.add(asset)
        session.commit()
    Path(replaces).unlink(missing_ok=True)
    return True


# ---------------------------------------------------------------------
# Async zpracování zpráv z streamu
# ---------------------------------------------------------------------

# Silné reference na úlohy běžící mimo job (upgrade, dobíhající YouTube).
_background_tasks: set[asyncio.Task] = set()


def _keep(task: asyncio.Task) -> asyncio.Task:
    _background_tasks.add(task)
    task.add_done_callback(_background_tasks.discard)
    return task


def _discard_when_done(task: asyncio.Task) -> None:
    """Prohraný YouTube download -- vlákno yt-dlp zrušit nejde, tak aspoň
    po doběhnutí smažeme jeho soubor."""

    def cleanup(t: asyncio.Task) -> None:
        if t.cancelled() or t.exception() is not None:
            return
        path = t.result().path
        try:
            path.unlink(missing_ok=True)
        except OSError:
            logger.warning("nepodařilo se smazat nepoužitý soubor %s", path)

    task.add_done_callback(cleanup)


def _spawn_upgrade(recording_id: str, slskd_task: asyncio.Task, replaces: Path) -> None:
    async def run() -> None:
        try:
            result: FetchResult = await slskd_task
        except Exception as exc:  # noqa: BLE001
            logger.info("upgrade %s: slskd nedodal lepší soubor (%s)", recording_id, exc)
            return
        item = json.dumps(
            {
                "recording_id": recording_id,
                "new_path": str(result.path),
                "replaces": str(replaces),
                "source": result.source_provider,
                "format": result.format,
                "bitrate": result.bitrate_kbps,
            }
        )
        await get_redis().zadd(UPGRADES_ZSET, {item: time.time() + UPGRADE_DELAY_S})
        logger.info("upgrade %s: %s připraven, prohodí se za %d s", recording_id, result.format, UPGRADE_DELAY_S)

    _keep(asyncio.create_task(run()))


async def _process_due_upgrades(r) -> None:
    items = await r.zrangebyscore(UPGRADES_ZSET, 0, time.time(), start=0, num=5)
    for item in items:
        if not await r.zrem(UPGRADES_ZSET, item):
            continue  # vzal si ho jiný worker
        data = json.loads(item)
        applied = await asyncio.to_thread(
            _apply_upgrade,
            data["recording_id"],
            data["new_path"],
            data["replaces"],
            data["source"],
            data["format"],
            data.get("bitrate"),
        )
        logger.info("upgrade %s: %s", data["recording_id"], "prohozeno" if applied else "zahozeno (asset se mezitím změnil)")
        if applied:
            _schedule_loudness(data["recording_id"])


async def _no_file_located(_path: Path) -> None:
    return None


async def _no_progress(_pct: int) -> None:
    return None


async def _acquire(
    r,
    job_id: str,
    track: TrackMetadata,
    interactive: bool,
    on_progress,
    on_file_located,
) -> FetchResult:
    """Obstará soubor. `interactive` (uživatel čeká): slskd a YouTube
    závodí souběžně, vyhrává kdo dřív dodá přehratelná data. Jinak slskd
    s kvalitním profilem a YouTube jen jako fallback -- ale když mezitím
    přijde eskalace (uživatel zmáčkl Přehrát na prefetchované skladbě),
    YouTube se přidá hned."""
    dest_stem = MEDIA_ROOT / track.recording_id
    if track.youtube_id and _youtube is not None:
        # Přesné YouTube video (odkaz / album jen na YouTube) -- rovnou ono.
        candidate = await _youtube.resolve(track)
        return await _youtube.fetch(track, candidate, dest_stem, on_progress, on_file_located)
    if _slskd is None or _youtube is None:
        candidate = await provider.resolve(track, interactive=interactive)
        if candidate is None:
            raise RuntimeError("žádný provider nenašel zdroj pro tuto skladbu")
        return await provider.fetch(track, candidate, dest_stem, on_progress, on_file_located)

    decided = False  # YouTube už vyhrál -> slskd běží jen jako upgrade
    streaming = False  # klient už přehrává rostoucí slskd soubor
    slskd_receiving = False  # slskd peer už posílá bajty
    max_pct = 0

    async def progress(pct: int) -> None:
        nonlocal max_pct
        if not decided and pct > max_pct:
            max_pct = pct
            await on_progress(pct)

    async def slskd_located(path: Path) -> None:
        nonlocal streaming, slskd_receiving
        slskd_receiving = True
        if decided:
            return
        streaming = True
        await on_file_located(path)

    async def run_slskd() -> FetchResult:
        candidate = await _slskd.resolve(track, interactive=interactive)
        if candidate is None:
            raise RuntimeError("slskd: žádný vhodný soubor")
        return await _slskd.fetch(track, candidate, dest_stem, progress, slskd_located)

    async def run_slskd_upgrade() -> FetchResult:
        # Trpělivý (background) profil -- interaktivní se vzdává peeru po 8 s,
        # na upgrade na pozadí je to zbytečně netrpělivé.
        candidate = await _slskd.resolve(track, interactive=False)
        if candidate is None:
            raise RuntimeError("slskd: žádný vhodný soubor")
        return await _slskd.fetch(track, candidate, dest_stem, _no_progress, _no_file_located)

    async def run_youtube() -> FetchResult:
        candidate = await _youtube.resolve(track)
        if candidate is None:
            raise RuntimeError("youtube: prázdný dotaz")
        return await _youtube.fetch(
            track, candidate, MEDIA_ROOT / f"{track.recording_id}_yt", progress, _no_file_located
        )

    started = time.monotonic()
    s_task = asyncio.create_task(run_slskd())
    y_task: asyncio.Task | None = asyncio.create_task(run_youtube()) if interactive else None
    escalate_key = job_escalate_key(job_id)
    try:
        while True:
            if s_task.done():
                s_exc = s_task.exception()
                if s_exc is None:
                    if y_task is not None:
                        _discard_when_done(y_task)
                    logger.info("job %s: vyhrál slskd za %.1f s", job_id, time.monotonic() - started)
                    return s_task.result()
                if y_task is None:
                    logger.info("job %s: slskd nevyšel (%s) -> YouTube", job_id, s_exc)
                    y_task = asyncio.create_task(run_youtube())

            if y_task is not None and y_task.done():
                y_exc = y_task.exception()
                if y_exc is None:
                    if streaming and not s_task.done():
                        pass  # klient už hraje slskd bajty; YouTube drž jako zálohu
                    else:
                        decided = True
                        result = y_task.result()
                        if not s_task.done() and slskd_receiving:
                            _spawn_upgrade(track.recording_id, s_task, result.path)
                        elif not s_task.done() or "žádný vhodný soubor" not in str(s_task.exception()):
                            # slskd ještě nic neposílá (nebo narazil na
                            # frontu/odmítnutí) -> zkusit znovu trpělivě.
                            if not s_task.done():
                                s_task.cancel()
                            _spawn_upgrade(
                                track.recording_id, asyncio.create_task(run_slskd_upgrade()), result.path
                            )
                        logger.info("job %s: vyhrál YouTube za %.1f s", job_id, time.monotonic() - started)
                        return result
                elif s_task.done():
                    raise RuntimeError(f"slskd: {s_task.exception()}; youtube: {y_exc}")

            if y_task is None and not s_task.done() and await r.get(escalate_key):
                logger.info("job %s eskalován (uživatel čeká) -> přidávám YouTube", job_id)
                y_task = asyncio.create_task(run_youtube())

            pending = [t for t in (s_task, y_task) if t is not None and not t.done()]
            if pending:
                await asyncio.wait(pending, timeout=0.5, return_when=asyncio.FIRST_COMPLETED)
    except BaseException:
        for t in (s_task, y_task):
            if t is not None and not t.done():
                t.cancel()
        raise


async def ensure_group(r, stream: str) -> None:
    try:
        await r.xgroup_create(stream, PROVISIONING_GROUP, id="0", mkstream=True)
    except Exception as exc:
        if "BUSYGROUP" not in str(exc):
            raise


async def _heartbeat(r, stream: str, message_id: str, lock_key: str) -> None:
    """Obnovuje zámek i "idle" čas zprávy v PEL -- dlouhý (slskd) job tak
    XAUTOCLAIM jiného workeru nepřevezme, dokud tenhle worker žije."""
    while True:
        await asyncio.sleep(HEARTBEAT_S)
        try:
            await r.expire(lock_key, LOCK_TTL_S)
            await r.xclaim(stream, PROVISIONING_GROUP, CONSUMER_NAME, 0, [message_id], justid=True)
        except Exception:  # noqa: BLE001
            logger.exception("heartbeat pro %s selhal", message_id)


async def process_message(r, stream: str, message_id: str, fields: dict) -> None:
    job_id = fields.get("job_id")
    if not job_id:
        logger.warning("zpráva %s bez job_id, ACKnuto a zahozeno", message_id)
        await r.xack(stream, PROVISIONING_GROUP, message_id)
        return

    interactive = stream == PROVISIONING_PRIORITY_STREAM
    lock_key = job_lock_key(job_id)
    if not await r.set(lock_key, CONSUMER_NAME, nx=True, ex=LOCK_TTL_S):
        # Job už zpracovává jiný (živý) worker -- duplicitní doručení nebo
        # prioritní kopie prefetchovaného jobu. Prioritní kopie aspoň
        # eskaluje běžící job na rychlou cestu.
        if interactive:
            await r.set(job_escalate_key(job_id), "1", ex=600)
        logger.info("job %s už zpracovává %s, zpráva %s přeskočena", job_id, await r.get(lock_key), message_id)
        await r.xack(stream, PROVISIONING_GROUP, message_id)
        return

    heartbeat = asyncio.create_task(_heartbeat(r, stream, message_id, lock_key))
    try:
        await handle_job(r, stream, job_id, interactive)
    finally:
        heartbeat.cancel()
        if await r.get(lock_key) == CONSUMER_NAME:
            await r.delete(lock_key)
        # ACKujeme vždy — úspěch, definitivní FAILED i retry (ten dostal
        # nové message id přes XADD), aby stejná zpráva nebyla doručena znovu.
        await r.xack(stream, PROVISIONING_GROUP, message_id)


def _remember_source_url(recording_id: str, url: str) -> None:
    """Odkaz na zdrojové YouTube video u skladby (detail, sdílení)."""
    with Session(engine) as session:
        recording = session.get(Recording, recording_id)
        if recording is None:
            return
        recording.external_refs = {**(recording.external_refs or {}), "youtubeUrl": url}
        session.add(recording)
        session.commit()


def _album_title(session: Session, recording: Recording | None) -> str | None:
    """Album skladby -- jen konkrétní vydání (album/EP), ne kompilace nebo
    singl stejného jména; podle něj se při stahování pozná správná verze."""
    if recording is None or not recording.release_id:
        return None
    from app.models import Release

    release = session.get(Release, recording.release_id)
    if release is None or (release.release_type or "album").lower() not in ("album", "ep"):
        return None
    if release.title.strip().lower() == (recording.title or "").strip().lower():
        return None  # titulní skladba -- album v názvu nic neříká
    return release.title


def _remember_source_key(recording_id: str, key: str) -> None:
    """Přesný zdroj souboru -- pro "Špatná verze -- stáhnout jinou"."""
    with Session(engine) as session:
        recording = session.get(Recording, recording_id)
        if recording is None:
            return
        recording.external_refs = {**(recording.external_refs or {}), "sourceKey": key}
        session.add(recording)
        session.commit()


async def handle_job(r, stream: str, job_id: str, interactive: bool) -> None:
    ctx = await asyncio.to_thread(_start_job, job_id)
    if ctx is None:
        logger.warning("job %s nenalezen v DB, ACKnuto a zahozeno", job_id)
        return
    if ctx["skip"]:
        return  # už vyřešeno dřívějším pokusem / duplicitní doručení

    if not interactive and await r.get(job_escalate_key(job_id)):
        interactive = True  # uživatel na skladbu klikl, než se job dostal na řadu

    await publish_job_progress(ctx["user_id"], job_id, ProvisioningJobStatus.RUNNING.value, pct=0)

    track = TrackMetadata(
        recording_id=ctx["recording_id"],
        title=ctx["recording_title"],
        artist_name=ctx.get("artist_name"),
        mbid=ctx.get("recording_mbid"),
        duration_ms=ctx.get("recording_duration_ms"),
        skip_candidates=ctx.get("skip_candidates", 0),
        youtube_id=ctx.get("youtube_id"),
        rejected_sources=tuple(ctx.get("rejected_sources") or ()),
        album_title=ctx.get("album_title"),
        preferred_source=ctx.get("preferred_source"),
    )

    async def on_progress(pct: int) -> None:
        await publish_job_progress(ctx["user_id"], job_id, ProvisioningJobStatus.RUNNING.value, pct=pct)

    async def on_file_located(path: Path) -> None:
        await asyncio.to_thread(_mark_downloading_path, ctx["recording_id"], str(path))
        await publish_track_streaming(
            ctx["user_id"], ctx["recording_id"], f"/api/v1/tracks/{ctx['recording_id']}/stream"
        )

    try:
        result = await _acquire(r, job_id, track, interactive, on_progress, on_file_located)
        checksum = await asyncio.to_thread(sha256_file, result.path)
        size = result.path.stat().st_size

        stream_url = await asyncio.to_thread(
            _finish_success,
            job_id,
            str(result.path),
            checksum,
            size,
            result.source_provider,
            result.format,
            result.bitrate_kbps,
        )
        if stream_url is None:
            logger.warning("job %s doběhl, ale byl už uzavřený jinde (duplicita) -- nic nepublikuji", job_id)
            return
        if result.source_url:
            await asyncio.to_thread(_remember_source_url, ctx["recording_id"], result.source_url)
        if result.source_key:
            await asyncio.to_thread(_remember_source_key, ctx["recording_id"], result.source_key)
        await publish_job_progress(ctx["user_id"], job_id, ProvisioningJobStatus.SUCCEEDED.value, pct=100)
        await publish_track_available(ctx["user_id"], ctx["recording_id"], stream_url)
        # Až PO `track.available` a fire-and-forget -- analýza nesmí zdržet
        # start přehrávání ani job označit jako selhaný.
        _schedule_loudness(ctx["recording_id"])
        _schedule_download_check(ctx["recording_id"])

    except Exception as exc:  # noqa: BLE001 - chceme zachytit *cokoliv* z providera
        logger.exception("provisioning jobu %s selhalo (pokus %s/%s)", job_id, ctx["attempts"], ctx["max_attempts"])
        should_retry = await asyncio.to_thread(
            _finish_failure, job_id, str(exc), ctx["attempts"], ctx["max_attempts"]
        )
        if should_retry is None:
            logger.warning("job %s selhal, ale byl už uzavřený jinde (duplicita) -- nic nepublikuji", job_id)
            return
        final_status = ProvisioningJobStatus.PENDING.value if should_retry else ProvisioningJobStatus.FAILED.value
        await publish_job_progress(ctx["user_id"], job_id, final_status, pct=None)
        if should_retry:
            await r.xadd(stream, {"job_id": job_id})


_running: dict[str, set[asyncio.Task]] = {PROVISIONING_PRIORITY_STREAM: set(), PROVISIONING_STREAM: set()}


def _spawn(r, stream: str, message_id: str, fields: dict) -> None:
    task = asyncio.create_task(process_message(r, stream, message_id, fields))
    bucket = _running[stream]
    bucket.add(task)

    def done(t: asyncio.Task) -> None:
        bucket.discard(t)
        if not t.cancelled() and t.exception() is not None:
            logger.error("zpracování zprávy %s spadlo", message_id, exc_info=t.exception())

    task.add_done_callback(done)


async def reclaim_stale(r) -> None:
    for stream in (PROVISIONING_PRIORITY_STREAM, PROVISIONING_STREAM):
        try:
            _cursor, claimed, _deleted = await r.xautoclaim(
                stream,
                PROVISIONING_GROUP,
                CONSUMER_NAME,
                min_idle_time=CLAIM_IDLE_MS,
                start_id="0-0",
                count=5,
            )
        except Exception:
            logger.exception("xautoclaim selhal (%s)", stream)
            continue
        for message_id, fields in claimed:
            if fields:  # smazané zprávy vrací xautoclaim bez polí
                _spawn(r, stream, message_id, fields)


_ORPHAN_AFTER_S = 120
_ORPHAN_SWEEP_KEY = "provisioning:orphan-sweep"


async def requeue_orphaned_jobs(r) -> None:
    """PENDING job, jehož zpráva se ztratila (worker zabitý dřív, než ji
    převzal/potvrdil; výpadek DB/Redis mezi zápisem jobu a XADD), by jinak
    visel navždy -- `/provision` pro stejnou skladbu vrací "už běží" a nic
    znovu nepošle (živě: 5 jobů zaseklých přes hodinu). Jednou za minutu
    (napříč replikami přes Redis zámek) je pošle do fronty znovu; duplicitu
    worker pozná podle zámku/stavu jobu, takže je to neškodné."""
    if not await r.set(_ORPHAN_SWEEP_KEY, CONSUMER_NAME, nx=True, ex=55):
        return
    cutoff = utcnow() - timedelta(seconds=_ORPHAN_AFTER_S)

    def stale_pending() -> list[str]:
        with Session(engine) as session:
            return list(
                session.exec(
                    select(ProvisioningJob.id).where(
                        ProvisioningJob.status == ProvisioningJobStatus.PENDING,
                        ProvisioningJob.created_at < cutoff,
                    )
                ).all()
            )

    for job_id in await asyncio.to_thread(stale_pending):
        if await r.exists(job_lock_key(job_id)):
            continue
        await r.xadd(PROVISIONING_STREAM, {"job_id": job_id})
        logger.warning("job %s visel ve stavu PENDING, posílám znovu do fronty", job_id)


async def main() -> None:
    init_db()
    r = get_redis()
    await ensure_group(r, PROVISIONING_STREAM)
    await ensure_group(r, PROVISIONING_PRIORITY_STREAM)
    logger.info(
        "worker %s startuje (interaktivní sloty %d, prefetch sloty %d)",
        CONSUMER_NAME,
        MAX_INTERACTIVE_JOBS,
        MAX_BACKGROUND_JOBS,
    )

    await reclaim_stale(r)
    last_housekeeping = time.monotonic()

    while True:
        if time.monotonic() - last_housekeeping > 15:
            last_housekeeping = time.monotonic()
            await reclaim_stale(r)
            try:
                await requeue_orphaned_jobs(r)
            except Exception:  # noqa: BLE001
                logger.exception("úklid zaseklých jobů selhal")
            try:
                await _process_due_upgrades(r)
            except Exception:  # noqa: BLE001
                logger.exception("zpracování upgradů selhalo")

        # Prioritní stream první (Redis vrací v pořadí klíčů); běžnou frontu
        # čteme jen s volnou kapacitou -- jinak by si worker zprávy
        # "zabral" a nechal je čekat, místo aby je vzal jiný volný worker.
        streams: dict[str, str] = {}
        if len(_running[PROVISIONING_PRIORITY_STREAM]) < MAX_INTERACTIVE_JOBS:
            streams[PROVISIONING_PRIORITY_STREAM] = ">"
        if len(_running[PROVISIONING_STREAM]) < MAX_BACKGROUND_JOBS:
            streams[PROVISIONING_STREAM] = ">"
        if not streams:
            await asyncio.sleep(0.2)
            continue

        resp = await r.xreadgroup(PROVISIONING_GROUP, CONSUMER_NAME, streams, count=1, block=BLOCK_MS)
        for stream_name, messages in resp or []:
            for message_id, fields in messages:
                _spawn(r, stream_name, message_id, fields)


if __name__ == "__main__":
    asyncio.run(main())
