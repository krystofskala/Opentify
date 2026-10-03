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


async def publish_job_progress(
    user_id: str, job_id: str, status: str, pct: int | None = None, error: str | None = None
) -> None:
    payload = {"jobId": job_id, "status": status, "pct": pct}
    if error:
        payload["error"] = error  # srozumitelný důvod pro uživatele ("Tuhle verzi nemáme")
    await publish_event(user_id, "job.progress", payload)


async def publish_track_available(user_id: str, recording_id: str, stream_url: str) -> None:
    await publish_event(
        user_id, "track.available", {"recordingId": recording_id, "streamUrl": stream_url}
    )


async def publish_track_streaming(user_id: str, recording_id: str, stream_url: str) -> None:
    """Na rozdíl od `track.available` (soubor je HOTOVÝ) tohle říká "soubor
    se sice ještě stahuje, ale `streamUrl` už je servírovatelný" -- viz
    `OnFileLocated` v app/providers.py a progresivní stream v
    `routes/provisioning.py`. Klient na oba eventy reaguje stejně (cokoliv
    s neprázdným `streamUrl` znamená "můžeš spustit `setUrl`")."""
    await publish_event(
        user_id, "track.streaming", {"recordingId": recording_id, "streamUrl": stream_url}
    )
