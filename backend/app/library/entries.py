"""Osobní knihovna profilu (viz `LibraryEntry`) -- admin má knihovnu =
všechno stažené, ostatní jen to, co si sami pustili, stáhli nebo lajkli."""

from __future__ import annotations

from sqlmodel import Session, select

from app.models import LibraryEntry


def add_to_library(session: Session, user_id: str, recording_id: str) -> None:
    # I admin -- jeho záznam "přebije" skladbu staženou jen jiným profilem
    # (pak se mu v knihovně ukáže, viz `_in_library`).
    exists = session.exec(
        select(LibraryEntry).where(LibraryEntry.user_id == user_id, LibraryEntry.recording_id == recording_id)
    ).first()
    if exists is None:
        session.add(LibraryEntry(user_id=user_id, recording_id=recording_id))
        session.commit()


def remove_from_library(session: Session, user_id: str, recording_id: str) -> bool:
    rows = session.exec(
        select(LibraryEntry).where(LibraryEntry.user_id == user_id, LibraryEntry.recording_id == recording_id)
    ).all()
    for row in rows:
        session.delete(row)
    session.commit()
    return bool(rows)
