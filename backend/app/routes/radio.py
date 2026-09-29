"""`/radio` -- nepřetržitý stream fronty pro iOS PWA (viz app/radio.py)."""

from __future__ import annotations

import re

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import StreamingResponse
from pydantic import BaseModel

from app import radio
from app.auth import get_current_user

radio_router = APIRouter(prefix="/radio", tags=["radio"])

_ID = re.compile(r"^[a-f0-9]{16,64}$")


class CreateBody(BaseModel):
    recordingIds: list[str]
    positionMs: float = 0


class QueueBody(BaseModel):
    upcoming: list[str]


def _check_id(session_id: str) -> None:
    if not _ID.match(session_id):
        raise HTTPException(status_code=400, detail="neplatné id relace")


@radio_router.put("/{session_id}")
def create(session_id: str, body: CreateBody, current: tuple[str, str] = Depends(get_current_user)):
    """Založí (nebo nahradí) relaci s id od klienta."""
    _check_id(session_id)
    if not body.recordingIds:
        raise HTTPException(status_code=400, detail="prázdná fronta")
    user_id, device_id = current
    radio.create_session(user_id, device_id, body.recordingIds, body.positionMs, session_id=session_id)
    return {"sessionId": session_id}


@radio_router.get("/{session_id}/stream")
async def stream(session_id: str):
    # Bez autentizační hlavičky -- <audio> ji neposílá; id relace je
    # náhodné a krátkodobé (a API je jen přes Tailscale).
    _check_id(session_id)
    s = await radio.wait_for_session(session_id)
    if s is None:
        raise HTTPException(status_code=404, detail="relace neexistuje")
    return StreamingResponse(
        radio.stream(s),
        media_type="audio/mpeg",
        headers={"Cache-Control": "no-store", "Accept-Ranges": "none", "X-Content-Type-Options": "nosniff"},
    )


@radio_router.get("/{session_id}/timeline")
def timeline(session_id: str, playedMs: float | None = None):
    s = radio.get_session(session_id)
    if s is None:
        raise HTTPException(status_code=404, detail="relace neexistuje")
    if playedMs is not None:
        s.played_ms = max(0.0, playedMs)
    return {
        "segments": [
            {
                "recordingId": seg.recording_id,
                "queuePos": seg.queue_pos,
                "startMs": seg.start_ms,
                "offsetMs": seg.offset_ms,
                "durationMs": seg.duration_ms,
                "trackMs": seg.track_ms,
            }
            for seg in s.timeline
        ]
    }


@radio_router.put("/{session_id}/queue")
def update_queue(session_id: str, body: QueueBody):
    s = radio.get_session(session_id)
    if s is None:
        raise HTTPException(status_code=404, detail="relace neexistuje")
    radio.update_upcoming(s, body.upcoming)
    return {"ok": True}
