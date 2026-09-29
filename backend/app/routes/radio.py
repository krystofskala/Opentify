"""`/radio` -- nepřetržitý stream fronty pro iOS PWA (viz app/radio.py)."""

from __future__ import annotations

import re

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse, Response, StreamingResponse
from pydantic import BaseModel

from app import radio
from app.auth import get_current_user

radio_router = APIRouter(prefix="/radio", tags=["radio"])

_ID = re.compile(r"^[a-f0-9]{16,64}$")


class CreateBody(BaseModel):
    recordingIds: list[str]
    positionMs: float = 0
    # A-B opakování první skladby (ms) -- server úsek řadí pořád dokola.
    abStartMs: float | None = None
    abEndMs: float | None = None


class QueueBody(BaseModel):
    upcoming: list[str]


def _check_id(session_id: str) -> None:
    if not _ID.match(session_id):
        raise HTTPException(status_code=400, detail="neplatné id relace")


@radio_router.put("/{session_id}")
async def create(session_id: str, body: CreateBody, current: tuple[str, str] = Depends(get_current_user)):
    """Založí (nebo nahradí) relaci s id od klienta."""
    _check_id(session_id)
    if not body.recordingIds:
        raise HTTPException(status_code=400, detail="prázdná fronta")
    user_id, device_id = current
    ab = (body.abStartMs, body.abEndMs) if body.abStartMs is not None and body.abEndMs is not None else None
    radio.create_session(user_id, device_id, body.recordingIds, body.positionMs, session_id=session_id, ab=ab)
    return {"sessionId": session_id}


@radio_router.get("/{session_id}/stream")
async def stream(session_id: str, request: Request):
    # Bez autentizační hlavičky -- <audio> ji neposílá; id relace je
    # náhodné a krátkodobé (a API je jen přes Tailscale).
    _check_id(session_id)
    s = await radio.wait_for_session(session_id)
    if s is None:
        raise HTTPException(status_code=404, detail="relace neexistuje")
    range_header = request.headers.get("range") or ""
    match = re.match(r"bytes=(\d+)-", range_header)
    start_byte = int(match.group(1)) if match else 0
    label = f"range={range_header or '-'} ua={(request.headers.get('user-agent') or '')[:60]}"
    return StreamingResponse(
        radio.stream(s, start_byte, label),
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


@radio_router.get("/{session_id}/index.m3u8")
async def hls_playlist(session_id: str):
    """HLS playlist pro iOS (viz app/radio.py -- AVPlayer stahuje i na pozadí)."""
    _check_id(session_id)
    s = await radio.wait_for_session(session_id)
    if s is None:
        raise HTTPException(status_code=404, detail="relace neexistuje")
    text = await radio.hls_playlist(s)
    if text is None:
        raise HTTPException(status_code=503, detail="stream se ještě připravuje")
    return Response(
        content=text,
        media_type="application/vnd.apple.mpegurl",
        headers={"Cache-Control": "no-cache, no-store"},
    )


_SEGMENT = re.compile(r"^seg\d{5}\.ts$")


@radio_router.get("/{session_id}/{name}")
def hls_segment(session_id: str, name: str):
    _check_id(session_id)
    if not _SEGMENT.match(name):
        raise HTTPException(status_code=404, detail="neznámý soubor")
    s = radio.get_session(session_id)
    path = radio.hls_segment_path(s, name) if s is not None else None
    if path is None:
        raise HTTPException(status_code=404, detail="úsek neexistuje")
    return FileResponse(path, media_type="video/mp2t", headers={"Cache-Control": "public, max-age=3600"})


@radio_router.put("/{session_id}/queue")
def update_queue(session_id: str, body: QueueBody):
    s = radio.get_session(session_id)
    if s is None:
        raise HTTPException(status_code=404, detail="relace neexistuje")
    radio.update_upcoming(s, body.upcoming)
    return {"ok": True}
