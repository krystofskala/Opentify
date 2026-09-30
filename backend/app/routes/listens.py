"""`/listens` -- poslechy hlášené klientem (scrobbling), viz app/listens.py."""

from __future__ import annotations

import asyncio
from datetime import datetime

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlmodel import Session, select

from app.auth import ADMIN_ID, get_current_user
from app.catalog.schemas import CamelModel
from app.db import get_session
from app.listens import record_listen, submit_playing_now
from app.models import Listen

listens_router = APIRouter(prefix="/listens", tags=["listens"])


class ListenIn(CamelModel):
    recording_id: str
    played_at: datetime | None = None
    duration_played_ms: int | None = None
    source: str | None = None
    context: str | None = None


class PlayingNowIn(CamelModel):
    recording_id: str


@listens_router.post("")
async def create_listen(body: ListenIn, current: tuple[str, str] = Depends(get_current_user)):
    user_id, _device = current
    listen_id = await asyncio.to_thread(
        record_listen,
        user_id,
        body.recording_id,
        played_at=body.played_at,
        duration_played_ms=body.duration_played_ms,
        source=body.source,
        context=body.context,
    )
    if listen_id is None:
        raise HTTPException(status_code=404, detail="nahrávka nenalezena")
    # Poslech = skladba v knihovně profilu (app/library/entries.py).
    from app.db import engine
    from app.library.entries import add_to_library
    from sqlmodel import Session

    def add() -> None:
        with Session(engine) as session:
            add_to_library(session, user_id, body.recording_id)

    await asyncio.to_thread(add)
    return {"id": listen_id}


@listens_router.post("/playing-now")
async def playing_now(body: PlayingNowIn, current: tuple[str, str] = Depends(get_current_user)):
    # "Právě hraje" na ListenBrainz jen za admina (jeho účet).
    if current[0] == ADMIN_ID:
        asyncio.create_task(submit_playing_now(body.recording_id))
    return {"ok": True}


@listens_router.get("")
def recent_listens(
    limit: int = Query(default=20, ge=1, le=200),
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device = current
    rows = session.exec(
        select(Listen).where(Listen.user_id == user_id).order_by(Listen.played_at.desc()).limit(limit)  # type: ignore[attr-defined]
    ).all()
    return [
        {
            "id": r.id,
            "recordingId": r.recording_id,
            "playedAt": r.played_at.isoformat(),
            "durationPlayedMs": r.duration_played_ms,
            "source": r.source,
            "submittedToListenBrainz": r.lb_submitted_at is not None,
            "lbError": r.lb_error,
        }
        for r in rows
    ]
