"""Synchronní jádro state machine, volané z FastAPI routy (viz
app/routes/provisioning.py). Zápisy do DB jsou tady sync/SQLModel; async
je jen `enqueue`, protože ten mluví s Redisem.
"""

from __future__ import annotations

import asyncio
import itertools
import json
import logging
import os
from pathlib import Path

from sqlalchemy.exc import IntegrityError
from sqlmodel import Session, select

from app.db import engine
from app.events import publish_job_progress
from app.models import (
    MediaAsset,
    MediaAssetStatus,
    ProvisioningJob,
    ProvisioningJobStatus,
    Recording,
)
from app.redis_bus import (
    PROVISIONING_PRIORITY_STREAM,
    PROVISIONING_STREAM,
    get_redis,
    job_escalate_key,
)
from app.utils import utcnow

logger = logging.getLogger("vault.provisioning")

ACTIVE_JOB_STATUSES = (ProvisioningJobStatus.PENDING, ProvisioningJobStatus.RUNNING)
MEDIA_ROOT = Path(os.environ.get("MEDIA_ROOT", "/data/media"))
# Čekající prohození YouTube souboru za lepší ze slskd (viz worker._spawn_upgrade).
UPGRADES_ZSET = "vault:provisioning:upgrades"
# Skladba se právě přehrává (`GET /stream`) -- přetagování ani upgrade ji
# do té doby nepřepíše (range requesty by dostaly bajty jiného souboru).
STREAMING_TTL_S = 15 * 60


def streaming_key(recording_id: str) -> str:
    return f"streaming:{recording_id}"


async def mark_streaming(recording_id: str) -> None:
    try:
        await get_redis().set(streaming_key(recording_id), "1", ex=STREAMING_TTL_S)
    except Exception:  # noqa: BLE001 - přehrávání kvůli Redisu nezdržovat
        logger.warning("nepodařilo se označit %s jako přehrávanou", recording_id)


async def is_streaming(r, recording_id: str) -> bool:
    try:
        return bool(await r.exists(streaming_key(recording_id)))
    except Exception:  # noqa: BLE001 - bez Redisu radši nepřepisovat
        return True


def stream_url_for(recording_id: str) -> str:
    return f"/api/v1/tracks/{recording_id}/stream"


def _file_missing(asset: MediaAsset) -> bool:
    """Náš stažený soubor (pod MEDIA_ROOT) zmizel z disku. Jen když je disk
    připojený -- odpojený disk nesmí spustit hromadné stahování znovu, a
    vlastní hudba mimo MEDIA_ROOT se nikdy nestahuje."""
    if not asset.storage_path:
        return True
    path = Path(asset.storage_path)
    if not path.is_relative_to(MEDIA_ROOT) or not _media_mounted():
        return False
    return not path.exists()


# Odpojený disk = prázdná složka bind mountu (adresář existuje dál), takže
# `is_dir()` nestačí -- jinak by se všechno označilo MISSING a stahovalo znovu.
_MOUNT_MARKER = "_zalohy"
_MIN_MEDIA_FILES = 20


def _media_mounted() -> bool:
    if not MEDIA_ROOT.is_dir():
        return False
    if (MEDIA_ROOT / _MOUNT_MARKER).is_dir():
        return True
    try:
        return sum(1 for _ in itertools.islice(MEDIA_ROOT.iterdir(), _MIN_MEDIA_FILES)) >= _MIN_MEDIA_FILES
    except OSError:
        return False


def heal_missing_file(session: Session, asset: MediaAsset) -> bool:
    """AVAILABLE asset bez souboru -> MISSING, ať se dá stáhnout znovu (dřív
    trvalé 409 "soubor chybí"). Před zápisem znovu načíst -- upgrade mohl
    právě prohodit soubor (nová cesta zapsaná, stará smazaná)."""
    if asset.status != MediaAssetStatus.AVAILABLE or not _file_missing(asset):
        return False
    session.commit()  # nová transakce, ať refresh vidí čerstvý stav (WAL snapshot)
    session.refresh(asset)
    if asset.status != MediaAssetStatus.AVAILABLE or not _file_missing(asset):
        return False
    logger.warning("soubor skladby %s chybí (%s) -- stáhne se znovu", asset.recording_id, asset.storage_path)
    asset.status = MediaAssetStatus.MISSING
    asset.storage_path = None
    asset.last_error = "soubor chyběl na disku"
    asset.updated_at = utcnow()
    session.add(asset)
    session.commit()
    session.refresh(asset)
    return True


def would_create_job(session: Session, recording_id: str) -> bool:
    """Založilo by `get_or_create_job` NOVÉ stahování? (pro limity: hotové a
    už běžící se nepočítají)."""
    asset = session.get(MediaAsset, recording_id)
    if asset is not None and asset.status == MediaAssetStatus.AVAILABLE and asset.storage_path:
        return False
    return session.exec(
        select(ProvisioningJob.id)
        .where(ProvisioningJob.recording_id == recording_id)
        .where(ProvisioningJob.status.in_(ACTIVE_JOB_STATUSES))
    ).first() is None


def get_or_create_job(
    session: Session, recording_id: str, user_id: str, device_id: str | None
) -> tuple[MediaAsset, ProvisioningJob | None, bool]:
    """Vrátí `(asset, job, created)`.

    - `job is None`      -> asset je AVAILABLE, volající rovnou vrátí stream.
    - `created is True`  -> nově založený job; volající HO MUSÍ publikovat
      do fronty (`enqueue`), jinak nikdy nikdo nezpracuje.
    - `created is False` a job existuje -> už běžící job ze staršího
      requestu; nic se znovu nepublikuje — to je zdroj idempotence
      endpointu při opakovaném volání/pollingu.
    """
    recording = session.get(Recording, recording_id)
    if recording is None:
        raise LookupError(recording_id)

    asset = session.get(MediaAsset, recording_id)
    if asset is None:
        asset = MediaAsset(recording_id=recording_id, status=MediaAssetStatus.MISSING)
        session.add(asset)
        try:
            session.commit()
        except IntegrityError:
            # Dva požadavky na tutéž skladbu naráz (dvě zařízení, dvojklik):
            # záznam mezitím založil ten druhý -- vzít jeho (8. 10.: 500).
            session.rollback()
            asset = session.get(MediaAsset, recording_id)
            if asset is None:
                raise
        session.refresh(asset)

    heal_missing_file(session, asset)
    if asset.status == MediaAssetStatus.AVAILABLE:
        return asset, None, False

    existing = session.exec(
        select(ProvisioningJob)
        .where(ProvisioningJob.recording_id == recording_id)
        .where(ProvisioningJob.status.in_(ACTIVE_JOB_STATUSES))
        .order_by(ProvisioningJob.created_at.desc())
    ).first()
    if existing is not None:
        return asset, existing, False

    job = ProvisioningJob(
        recording_id=recording_id,
        requested_by_user_id=user_id,
        requested_by_device_id=device_id,
        status=ProvisioningJobStatus.PENDING,
    )
    asset.status = MediaAssetStatus.QUEUED
    session.add(job)
    session.add(asset)
    session.commit()
    session.refresh(job)
    return asset, job, True


def _unlink_unless_live(recording_id: str, path: str) -> None:
    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        if asset is not None and asset.storage_path == path:
            return
    Path(path).unlink(missing_ok=True)


async def cancel_upgrades(r, recording_id: str) -> int:
    """Zahodí čekající upgrady skladby -- nový job (typicky "Špatná verze")
    znamená, že soubor, který měl upgrade nahradit, už neplatí. Jejich
    soubory se smažou, pokud to mezitím nejsou živé soubory skladby."""
    removed = 0
    try:
        items = await r.zrange(UPGRADES_ZSET, 0, -1)
    except Exception:  # noqa: BLE001 - upgrade by stejně neprošel kontrolou asset cesty
        return 0
    for item in items:
        try:
            data = json.loads(item)
        except ValueError:
            continue
        if data.get("recording_id") != recording_id or not await r.zrem(UPGRADES_ZSET, item):
            continue
        removed += 1
        new_path = data.get("new_path")
        if new_path and Path(new_path).is_relative_to(MEDIA_ROOT):
            await asyncio.to_thread(_unlink_unless_live, recording_id, new_path)
    if removed:
        logger.info("skladba %s: zrušeno %d čekajících upgradů", recording_id, removed)
    return removed


async def enqueue(job: ProvisioningJob, *, interactive: bool = False) -> None:
    r = get_redis()
    await cancel_upgrades(r, job.recording_id)
    stream = PROVISIONING_PRIORITY_STREAM if interactive else PROVISIONING_STREAM
    await r.xadd(stream, {"job_id": job.id})
    await publish_job_progress(job.requested_by_user_id, job.id, ProvisioningJobStatus.PENDING.value)


async def escalate(job: ProvisioningJob) -> None:
    """Uživatel chce přehrát skladbu, jejíž job už existuje (typicky ho
    založil prefetch alba). Job ještě ve frontě -> duplicitní zpráva do
    prioritního streamu ho předběhne (worker duplicitu pozná podle zámku /
    stavu jobu). Job už běží -> escalate flag, běžící worker přidá rychlou
    cestu. Opakované volání je neškodné."""
    r = get_redis()
    await r.set(job_escalate_key(job.id), "1", ex=600)
    if job.status == ProvisioningJobStatus.PENDING:
        await r.xadd(PROVISIONING_PRIORITY_STREAM, {"job_id": job.id})
