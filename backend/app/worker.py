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
import dataclasses
import json
import re
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
from app.catalog.non_music import is_non_music
from app.download_match import match_label
from app.models import (
    Artist,
    MediaAsset,
    MediaAssetStatus,
    ProvisioningJob,
    ProvisioningJobStatus,
    Recording,
    Release,
)
from app.providers import (
    CompositeProvider,
    FetchResult,
    SlskdProvider,
    SoundcloudProvider,
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
try:
    from logging.handlers import RotatingFileHandler

    Path("/data/db/logs").mkdir(parents=True, exist_ok=True)
    # Každé nasazení = nový kontejner = nový soubor; staré po 14 dnech pryč.
    import time as _time

    for _old in Path("/data/db/logs").glob("worker-*.log*"):
        if _time.time() - _old.stat().st_mtime > 14 * 86400:
            _old.unlink(missing_ok=True)
    _file_log = RotatingFileHandler(
        f"/data/db/logs/worker-{socket.gethostname()}.log", maxBytes=5_000_000, backupCount=3, encoding="utf-8"
    )
    _file_log.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    _file_log.setLevel(logging.INFO)
    logging.getLogger().addHandler(_file_log)
except OSError:
    pass  # mimo Docker (testy) -- jen konzole
logger = logging.getLogger("vault.worker")

MEDIA_ROOT = Path(os.environ.get("MEDIA_ROOT", "/data/media"))
CONSUMER_NAME = f"worker-{socket.gethostname()}-{os.getpid()}"
CLAIM_IDLE_MS = 60_000  # zprávy visící > 60s u mrtvého konzumenta se přeberou
BLOCK_MS = 1_000
# Zámek musí vypršet DŘÍV, než XAUTOCLAIM převezme zprávu mrtvého workeru --
# jinak nový worker narazí na "živý" zámek, zprávu zahodí a job zůstane
# navždy RUNNING (živě 2 joby).
LOCK_TTL_S = 45
HEARTBEAT_S = 15
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
_soundcloud = SoundcloudProvider()
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
            "track_number": recording.track_number if recording else None,
            "isrc": recording.isrc if recording else None,
            "deezer_id": recording.deezer_id if recording else None,
            "rejected_fps": tuple((recording.external_refs or {}).get("rejectedFingerprints") or []) if recording else (),
            "artist_name": artist.name if artist else None,
            "album_title": _album_title(session, recording),
            "version_hint": _version_hint(session, recording),
            "preferred_source": (recording.external_refs or {}).get("preferredSource") if recording else None,
            # Dřív "přeskoč N výsledků" -- teď se zakazuje přesný zdroj a otisk
            # zvuku (rejectedSources/rejectedFingerprints), přeskakování by jen
            # zahodilo dobré kandidáty.
            "skip_candidates": 0,
            "rejected_sources": list((recording.external_refs or {}).get("rejectedSources") or []) if recording else [],
            "youtube_id": (recording.external_refs or {}).get("youtubeId") if recording else None,
            "soundcloud_url": (recording.external_refs or {}).get("soundcloudUrl") if recording else None,
            "attempts": job.attempts,
            "max_attempts": job.max_attempts,
            "non_music": is_non_music(session.get(Release, recording.release_id))
            if recording and recording.release_id
            else False,
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


def _mark_interactive(job_id: str, interactive: bool) -> None:
    with Session(engine) as session:
        job = session.get(ProvisioningJob, job_id)
        if job is not None:
            job.interactive = interactive
            session.add(job)
            session.commit()


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
        job.source_provider = source_provider
        job.audio_format = audio_format

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


def _apply_upgrade(
    recording_id: str,
    new_path: str,
    replaces: str,
    source: str,
    audio_format: str,
    bitrate: int | None,
    source_key: str | None = None,
) -> bool:
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
        recording = session.get(Recording, recording_id)
        if recording is not None and source_key:
            # Zdroj je teď slskd soubor -- "Špatná verze" musí odmítnout ten,
            # ne původní YouTube video.
            refs = {**(recording.external_refs or {}), "sourceKey": source_key}
            refs.pop("youtubeUrl", None)
            recording.external_refs = refs
            session.add(recording)
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
                "source_key": result.source_key,
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
        # Lepší soubor ze Soulseeku musí projít stejnou kontrolou -- dřív se
        # správné YouTube audio dalo tiše prohodit za jinou skladbu.
        target = await asyncio.to_thread(_target_from_db, data["recording_id"], data["source"])
        if target is not None:
            from app.library.verify_file import verify

            verdict = await verify(Path(data["new_path"]), target, full_decode=True)
            if not verdict.ok:
                logger.warning("upgrade %s: soubor neprošel kontrolou (%s) -- ponechán původní", data["recording_id"], verdict.reason)
                (verdict.path or Path(data["new_path"])).unlink(missing_ok=True)
                await asyncio.to_thread(_reject_source, data["recording_id"], data.get("source_key"), verdict.reason)
                continue
            if verdict.path and str(verdict.path) != data["new_path"]:
                data["new_path"] = str(verdict.path)
                data["format"] = verdict.path.suffix.lstrip(".")
        applied = await asyncio.to_thread(
            _apply_upgrade,
            data["recording_id"],
            data["new_path"],
            data["replaces"],
            data["source"],
            data["format"],
            data.get("bitrate"),
            data.get("source_key"),
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
    if track.soundcloud_url and not track.preferred_source:
        # Přesná skladba ze SoundCloudu (odkaz / nevydaná věc) -- rovnou ona.
        candidate = await _soundcloud.resolve(track)
        return await _soundcloud.fetch(track, candidate, dest_stem, on_progress, on_file_located)
    if track.youtube_id and _youtube is not None and not track.preferred_source:
        # Přesné YouTube video (odkaz / album jen na YouTube) -- rovnou ono.
        # Když je album ale nalezené jako složka na Soulseeku (preferredSource),
        # má přednost Soulseek (lepší kvalita), video zůstává jako záloha.
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
                    # Poslední záloha: SoundCloud (dema, remixy, nevydané věci).
                    try:
                        sc_candidate = await _soundcloud.resolve(track)
                        if sc_candidate is not None:
                            logger.info("job %s: slskd i YouTube nevyšly -> SoundCloud", job_id)
                            return await _soundcloud.fetch(track, sc_candidate, dest_stem, progress, _no_file_located)
                    except Exception as sc_exc:  # noqa: BLE001
                        raise RuntimeError(
                            f"slskd: {s_task.exception()}; youtube: {y_exc}; soundcloud: {sc_exc}"
                        ) from sc_exc
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


def _verify_target(track: TrackMetadata, ctx: dict, provider_name: str) -> "Target":
    from app.library.verify_file import Target

    return Target(
        recording_id=track.recording_id,
        title=track.title,
        artist=track.artist_name,
        album=track.album_title,
        expected_ms=track.duration_ms,
        deezer_id=ctx.get("deezer_id"),
        isrc=track.isrc,
        mbid=track.mbid,
        provider=provider_name,
        rejected_fps=tuple(ctx.get("rejected_fps") or ()),
    )


def _reject_source(recording_id: str, key: str | None, reason: str, fp: str | None = None) -> None:
    """Zdroj neprošel kontrolou -- už nikdy znovu (rejectedSources), a ani
    stejný zvuk z jiného zdroje (rejectedFingerprints)."""
    with Session(engine) as session:
        recording = session.get(Recording, recording_id)
        if recording is None:
            return
        refs = dict(recording.external_refs or {})
        if fp:
            refs["rejectedFingerprints"] = [*(refs.get("rejectedFingerprints") or [])[-4:], fp]
        if key:
            rejected = list(refs.get("rejectedSources") or [])
            if key not in rejected:
                rejected.append(key)
            refs["rejectedSources"] = rejected
            if refs.get("sourceKey") == key:
                refs.pop("sourceKey", None)
            if key.startswith("youtube:") and key.split(":", 1)[1] in str(refs.get("youtubeUrl") or ""):
                refs.pop("youtubeUrl", None)
        refs["lastRejected"] = {"source": key, "reason": reason[:300], "at": utcnow().isoformat()}
        recording.external_refs = refs
        session.add(recording)
        session.commit()


def _target_from_db(recording_id: str, provider_name: str):
    from app.library.verify_file import Target

    with Session(engine) as session:
        recording = session.get(Recording, recording_id)
        if recording is None:
            return None
        artist = session.get(Artist, recording.artist_id) if recording.artist_id else None
        return Target(
            recording_id=recording_id,
            title=recording.title,
            artist=artist.name if artist else None,
            album=_album_title(session, recording),
            expected_ms=recording.duration_ms,
            deezer_id=recording.deezer_id,
            isrc=recording.isrc,
            mbid=recording.mbid,
            provider=provider_name,
        )


def _store_duration(recording_id: str, ms: int, deezer_id: str | None) -> None:
    with Session(engine) as session:
        recording = session.get(Recording, recording_id)
        if recording is None or recording.duration_ms:
            return
        recording.duration_ms = ms
        if deezer_id and not recording.deezer_id:
            from app.models import Recording as _R

            taken = session.exec(select(_R.id).where(_R.deezer_id == deezer_id)).first()
            if taken is None:
                recording.deezer_id = deezer_id
        recording.external_refs = {**(recording.external_refs or {}), "durationSource": "deezer"}
        session.add(recording)
        session.commit()


def _is_missing_version(message: str) -> bool:
    """Selhání = "nenašli jsme tu verzi" (ne výpadek sítě / zdroje)."""
    low = message.lower()
    return "nemáme" in low or "v téhle verzi" in low or (
        "žádný vhodný soubor" in low and ("youtube" not in low or "nemá" in low)
    )


async def _deezer_title(deezer_id: str) -> str | None:
    from app.catalog.deezer import get_deezer_client

    try:
        track = await get_deezer_client().track(str(deezer_id))
    except Exception:  # noqa: BLE001
        return None
    return (track or {}).get("title")


MAX_VERIFY_ROUNDS = 3


async def _acquire_verified(r, job_id: str, track: TrackMetadata, ctx: dict, interactive: bool, on_progress, on_file_located) -> FetchResult:
    """`_acquire` + kontrola souboru PŘED zpřístupněním (app/library/verify_file.py).
    Neprošlý soubor se smaže, zdroj se zakáže a zkusí se další kandidát --
    radši "nemáme" než jiná verze. Přesné video/odkaz od uživatele se neověřuje."""
    from app.library.verify_file import verify

    explicit = bool(track.youtube_id or track.soundcloud_url) and not track.preferred_source
    reasons: list[str] = []
    for _round in range(MAX_VERIFY_ROUNDS):
        result = await _acquire(r, job_id, track, interactive, on_progress, on_file_located)
        if explicit:
            return result
        verdict = await verify(
            result.path, _verify_target(track, ctx, result.source_provider), full_decode=result.source_provider == "slskd"
        )
        if verdict.ok:
            if verdict.path and verdict.path != result.path:
                result = dataclasses.replace(result, path=verdict.path, format=verdict.path.suffix.lstrip("."))
            if result.bitrate_kbps is None and verdict.details.get("kbps"):
                result = dataclasses.replace(result, bitrate_kbps=verdict.details["kbps"])
            logger.info("job %s: soubor ověřen (%s, %s) %s", job_id, verdict.reason, verdict.confidence, verdict.details.get("ber"))
            return dataclasses.replace(result, verified=verdict.confidence)
        logger.warning("job %s: soubor z %s NEPROŠEL kontrolou: %s (%s)", job_id, result.source_key, verdict.reason, verdict.details)
        reasons.append(verdict.reason)
        from app.library.verify_file import fingerprint_worth_keeping, signature

        fp = await signature(verdict.path or result.path) if fingerprint_worth_keeping(verdict.reason) else None
        (verdict.path or result.path).unlink(missing_ok=True)
        await asyncio.to_thread(_reject_source, track.recording_id, result.source_key, verdict.reason, fp)
        if fp:
            ctx["rejected_fps"] = (*ctx.get("rejected_fps", ()), fp)
        if not result.source_key:
            break  # nevíme, co zakázat -- další kolo by stáhlo totéž
        track = dataclasses.replace(track, rejected_sources=(*track.rejected_sources, result.source_key), preferred_source=None)
    raise RuntimeError(f"Nemáme tuhle verzi: žádný zdroj neprošel kontrolou ({'; '.join(reasons)})")


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


_LIVE_RELEASE_RE = re.compile(r"^\s*(?:\d{4}-\d{2}-\d{2}|\d{4}-\d{2}|\d{1,2}\.\d{1,2}\.\d{4})\s*[:\-–]")


# "Live at/in/from...", "(Live)", "Unplugged", "In Concert" -- ne "Live
# Through This" (studiové album Hole).
_LIVE_ALBUM_RE = re.compile(
    r"\blive (?:at|in|from|on|aus|au|à)\b|[\(\[]\s*live\b|\blive\s*[\)\]]|\s[-–]\s*live\b|^live$"
    r"|\bunplugged\b|\bin concert\b|\bkoncert\b|\bnaživo\b",
    re.I,
)


def _version_hint(session: Session, recording: Recording | None) -> str | None:
    """Verze daná vydáním, ne názvem: živák / bootleg koncertu ("2000-08-23:
    Alltel Pavilion..."), demo. Bez téhle nápovědy se stáhla studiová verze."""
    if recording is None:
        return None
    # Poznámka MusicBrainz přímo u nahrávky ("live, 1994-05-02: Glastonbury",
    # "demo", "acoustic") -- nejpřesnější, platí i mimo živé album.
    note = ((recording.external_refs or {}).get("mbDisambiguation") or "").lower()
    for word in ("live", "demo", "acoustic"):
        if re.search(rf"\b{word}\b", note):
            return word
    if not recording.release_id:
        return None
    from app.models import Release

    release = session.get(Release, recording.release_id)
    if release is None:
        return None
    refs = release.external_refs or {}
    rarity = refs.get("rarity")
    secondary = set(refs.get("mbSecondary") or [])
    if rarity == "demo" or "demo" in secondary:
        return "demo"
    if rarity in ("live", "bootleg") or "live" in secondary or _LIVE_RELEASE_RE.match(release.title or ""):
        return "live"
    # Živé album ("MTV Unplugged in New York", "Live at ...") -- skladby z něj
    # jsou živé, i když to jejich název neříká.
    if _LIVE_ALBUM_RE.search(release.title or ""):
        return "live"
    return None


def _remember_source_key(recording_id: str, key: str, tier: int | None = None) -> None:
    """Přesný zdroj souboru -- pro "Špatná verze -- stáhnout jinou"."""
    with Session(engine) as session:
        recording = session.get(Recording, recording_id)
        if recording is None:
            return
        refs = {**(recording.external_refs or {}), "sourceKey": key}
        # Videoklip (ne oficiální audio stopa) -- intro navíc rozhodí text;
        # denně se zkusí nahradit čistým audiem (tools/upgrade_video_audio.py).
        if key.startswith("youtube:") and tier is not None and tier > 0:
            refs["videoSource"] = True
        else:
            refs.pop("videoSource", None)
        recording.external_refs = refs
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

    if ctx.get("non_music"):
        # Rozhovor / mluvené slovo (app/catalog/non_music.py): nestahovat
        # nic -- jinak by se pod názvem písně ("Video Games") přehrál
        # rozhovor, nebo naopak píseň pod rozhovorem.
        if await asyncio.to_thread(_finish_failure, job_id, "rozhovor, ne hudba", 1, 1) is not None:
            await publish_job_progress(ctx["user_id"], job_id, ProvisioningJobStatus.FAILED.value, pct=None)
        return

    await publish_job_progress(ctx["user_id"], job_id, ProvisioningJobStatus.RUNNING.value, pct=0)
    await asyncio.to_thread(_mark_interactive, job_id, interactive)

    track = TrackMetadata(
        recording_id=ctx["recording_id"],
        title=ctx["recording_title"],
        artist_name=ctx.get("artist_name"),
        mbid=ctx.get("recording_mbid"),
        duration_ms=ctx.get("recording_duration_ms"),
        skip_candidates=ctx.get("skip_candidates", 0),
        youtube_id=ctx.get("youtube_id"),
        soundcloud_url=ctx.get("soundcloud_url"),
        rejected_sources=tuple(ctx.get("rejected_sources") or ()),
        album_title=ctx.get("album_title"),
        track_number=ctx.get("track_number"),
        isrc=ctx.get("isrc"),
        version_hint=ctx.get("version_hint"),
        preferred_source=ctx.get("preferred_source"),
    )

    if ctx.get("deezer_id") and not (track.youtube_id or track.soundcloud_url):
        # Název přesné verze na Deezeru, je-li jinak napsaný (japonský název
        # vs. anglický "In the Rain") -- kandidáti pak projdou i pod ním a
        # správnost ověří otisk ukázky té verze.
        alt = await _deezer_title(ctx["deezer_id"])
        if alt and match_label(track.title, alt) is not None and match_label(alt, track.title) is not None:
            track = dataclasses.replace(track, alt_titles=(alt,))

    if not track.duration_ms and not (track.youtube_id or track.soundcloud_url):
        # Bez délky by se kandidáti nedali ověřit -- dohledat (jistá shoda).
        from app.library.verify_file import resolve_duration

        ms, dz_id = await resolve_duration(_verify_target(track, ctx, ""))
        if ms:
            track = dataclasses.replace(track, duration_ms=ms)
            ctx["deezer_id"] = ctx.get("deezer_id") or dz_id
            await asyncio.to_thread(_store_duration, track.recording_id, ms, dz_id)

    async def on_progress(pct: int) -> None:
        await publish_job_progress(ctx["user_id"], job_id, ProvisioningJobStatus.RUNNING.value, pct=pct)

    async def on_file_located(path: Path) -> None:
        await asyncio.to_thread(_mark_downloading_path, ctx["recording_id"], str(path))
        await publish_track_streaming(
            ctx["user_id"], ctx["recording_id"], f"/api/v1/tracks/{ctx['recording_id']}/stream"
        )

    try:
        result = await _acquire_verified(r, job_id, track, ctx, interactive, on_progress, on_file_located)
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
            await asyncio.to_thread(_remember_source_key, ctx["recording_id"], result.source_key, result.source_tier)
        await publish_job_progress(ctx["user_id"], job_id, ProvisioningJobStatus.SUCCEEDED.value, pct=100)
        await publish_track_available(ctx["user_id"], ctx["recording_id"], stream_url)
        # Až PO `track.available` a fire-and-forget -- analýza nesmí zdržet
        # start přehrávání ani job označit jako selhaný.
        _schedule_loudness(ctx["recording_id"])
        if result.verified != "high":  # otiskem potvrzené už Shazam nepotřebuje
            _schedule_download_check(ctx["recording_id"])

    except Exception as exc:  # noqa: BLE001 - chceme zachytit *cokoliv* z providera
        logger.exception("provisioning jobu %s selhalo (pokus %s/%s)", job_id, ctx["attempts"], ctx["max_attempts"])
        # "Nemáme" (nic neprošlo pravidly / kontrolou) je konečný výsledek --
        # opakování za 30 s by našlo totéž a uživatel by jen čekal.
        missing = _is_missing_version(str(exc))
        should_retry = await asyncio.to_thread(
            _finish_failure,
            job_id,
            str(exc),
            ctx["max_attempts"] if missing else ctx["attempts"],
            ctx["max_attempts"],
        )
        if should_retry is None:
            logger.warning("job %s selhal, ale byl už uzavřený jinde (duplicita) -- nic nepublikuji", job_id)
            return
        final_status = ProvisioningJobStatus.PENDING.value if should_retry else ProvisioningJobStatus.FAILED.value
        await publish_job_progress(
            ctx["user_id"],
            job_id,
            final_status,
            pct=None,
            error=None if should_retry else ("Tuhle verzi nemáme" if missing else "Stažení se nepodařilo"),
        )
        if should_retry:
            # Prodleva podle pokusu (30 s, 60 s, ...) -- okamžitý nový pokus
            # narážel na stejný výpadek / bot-blok. Kdyby worker mezitím
            # skončil, job visí PENDING a vrátí ho úklid (requeue_orphaned_jobs).
            delay = 30 * ctx["attempts"]

            async def requeue_later() -> None:
                await asyncio.sleep(delay)
                await r.xadd(stream, {"job_id": job_id})

            _keep(asyncio.create_task(requeue_later()))


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


_ORPHAN_AFTER_S = 600
_RUNNING_ORPHAN_AFTER_S = 300
_ORPHAN_SWEEP_KEY = "provisioning:orphan-sweep"
_REQUEUED_KEY = "provisioning:requeued:{}"


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
    running_cutoff = utcnow() - timedelta(seconds=_RUNNING_ORPHAN_AFTER_S)

    def stale() -> list[str]:
        with Session(engine) as session:
            pending = session.exec(
                select(ProvisioningJob.id).where(
                    ProvisioningJob.status == ProvisioningJobStatus.PENDING,
                    ProvisioningJob.created_at < cutoff,
                )
            ).all()
            # RUNNING bez zámku = worker umřel uprostřed (zámek vypršel).
            running = session.exec(
                select(ProvisioningJob.id).where(
                    ProvisioningJob.status == ProvisioningJobStatus.RUNNING,
                    ProvisioningJob.started_at < running_cutoff,  # type: ignore[operator]
                )
            ).all()
            return list(pending) + list(running)

    for job_id in await asyncio.to_thread(stale):
        if await r.exists(job_lock_key(job_id)):
            continue
        # Dlouhá fronta prefetchů: PENDING job tam pořád čeká -- bez tohohle
        # by se každou minutu přidala další kopie (stream rostl donekonečna).
        if not await r.set(_REQUEUED_KEY.format(job_id), "1", nx=True, ex=1800):
            continue
        await r.xadd(PROVISIONING_STREAM, {"job_id": job_id})
        logger.warning("job %s visel (bez workeru), posílám znovu do fronty", job_id)


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
