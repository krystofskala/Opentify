"""Publikování WS eventů (viz docs/asyncapi.yaml) přes Redis pub/sub.

Tvar zpráv je 1:1 s `components.messages` v asyncapi.yaml, aby realtime hub
(app/realtime.py) mohl payload jen přeposlat na WS bez další transformace.
"""

from __future__ import annotations

import json
from typing import Any

from app.redis_bus import get_redis, user_events_channel


async def publish_event(user_id: str, event_type: str, payload: dict[str, Any]) -> None:
    message = json.dumps({"type": event_type, "payload": payload})
    await get_redis().publish(user_events_channel(user_id), message)


WATCH_TTL_S = 6 * 3600


def job_watchers_key(job_id: str) -> str:
    return f"job:watchers:{job_id}"


def recording_watchers_key(recording_id: str) -> str:
    return f"rec:watchers:{recording_id}"


async def watch(job_id: str, recording_id: str, user_id: str) -> None:
    """Druhý profil čeká na job, který založil někdo jiný (táta stahuje
    tutéž skladbu) -- dostane taky jeho události, jinak by se mu točilo
    kolečko, dokud ho nespasí watchdog."""
    r = get_redis()
    for key in (job_watchers_key(job_id), recording_watchers_key(recording_id)):
        await r.sadd(key, user_id)
        await r.expire(key, WATCH_TTL_S)


async def _targets(user_id: str, key: str) -> set[str]:
    try:
        members = await get_redis().smembers(key)
    except Exception:  # noqa: BLE001 -- Redis výpadek: aspoň zakladatel
        members = set()
    return {user_id} | {m.decode() if isinstance(m, bytes) else m for m in members}


async def publish_job_progress(
    user_id: str, job_id: str, status: str, pct: int | None = None, error: str | None = None
) -> None:
    payload = {"jobId": job_id, "status": status, "pct": pct}
    if error:
        payload["error"] = error  # srozumitelný důvod pro uživatele ("Tuhle verzi nemáme")
    for target in await _targets(user_id, job_watchers_key(job_id)):
        await publish_event(target, "job.progress", payload)


async def publish_track_available(user_id: str, recording_id: str, stream_url: str) -> None:
    for target in await _targets(user_id, recording_watchers_key(recording_id)):
        await publish_event(
            target, "track.available", {"recordingId": recording_id, "streamUrl": stream_url}
        )


async def publish_track_streaming(user_id: str, recording_id: str, stream_url: str) -> None:
    """Na rozdíl od `track.available` (soubor je HOTOVÝ) tohle říká "soubor
    se sice ještě stahuje, ale `streamUrl` už je servírovatelný" -- viz
    `OnFileLocated` v app/providers.py a progresivní stream v
    `routes/provisioning.py`. Klient na oba eventy reaguje stejně (cokoliv
    s neprázdným `streamUrl` znamená "můžeš spustit `setUrl`")."""
    for target in await _targets(user_id, recording_watchers_key(recording_id)):
        await publish_event(
            target, "track.streaming", {"recordingId": recording_id, "streamUrl": stream_url}
        )
