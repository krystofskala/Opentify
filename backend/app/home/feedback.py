""""Víc / míň takových" (plán P2) -- ruční posun interpreta v mixech a v
Pusť teď. Každé klepnutí ±5, celkem nejvýš ±15. Míň na −15 = interpret se
prakticky přestane objevovat (na rozdíl od "Nelíbí se" ale nezmizí úplně z
doporučení a jde snadno vrátit)."""

from __future__ import annotations

from sqlmodel import Session, select

from app.db import engine
from app.models import ArtistFeedback, Recording
from app.utils import utcnow

STEP = 5.0
LIMIT = 15.0


def set_feedback(user_id: str, artist_id: str, direction: str) -> float:
    from app.locks import keyed

    step = STEP if direction == "more" else -STEP
    with keyed(f"feedback:{user_id}:{artist_id}"), Session(engine) as session:
        row = session.get(ArtistFeedback, (user_id, artist_id)) or ArtistFeedback(user_id=user_id, artist_id=artist_id)
        row.delta = max(-LIMIT, min(LIMIT, row.delta + step))
        row.updated_at = utcnow()
        session.add(row)
        session.commit()
        return row.delta


def clear(user_id: str, artist_id: str) -> None:
    with Session(engine) as session:
        row = session.get(ArtistFeedback, (user_id, artist_id))
        if row is not None:
            session.delete(row)
            session.commit()


def deltas(user_id: str) -> dict[str, float]:
    with Session(engine) as session:
        rows = session.exec(select(ArtistFeedback).where(ArtistFeedback.user_id == user_id)).all()
    return {r.artist_id: r.delta for r in rows if r.delta}


def artist_for(recording_id: str) -> str | None:
    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
        return rec.artist_id if rec else None


def fit_multiplier(delta: float) -> float:
    """Pro Pusť teď: +15 -> 2,5×, −15 -> skoro nic."""
    return 1 + delta / 10 if delta >= 0 else max(0.05, 1 + delta / 10)
