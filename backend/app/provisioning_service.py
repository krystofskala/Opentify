"""Synchronní jádro state machine, volané z FastAPI routy (viz
app/routes/provisioning.py). Zápisy do DB jsou tady sync/SQLModel; async
je jen `enqueue`, protože ten mluví s Redisem.
"""

from __future__ import annotations

from sqlmodel import Session, select

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

ACTIVE_JOB_STATUSES = (ProvisioningJobStatus.PENDING, ProvisioningJobStatus.RUNNING)


def stream_url_for(recording_id: str) -> str:
    return f"/api/v1/tracks/{recording_id}/stream"


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
        session.commit()
        session.refresh(asset)

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


async def enqueue(job: ProvisioningJob, *, interactive: bool = False) -> None:
    r = get_redis()
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
