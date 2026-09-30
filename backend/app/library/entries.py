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


def seed_admin_library() -> int:
    """Jednorázově při přechodu na klasickou knihovnu: všechno, co měl admin
    v knihovně dosud (= vše stažené), se zapíše jako přidané -- nic mu
    nezmizí. Pak už jen explicitní "Přidat do knihovny"/lajk."""
    from app.auth import ADMIN_ID
    from app.db import engine
    from app.models import HomeSnapshot, MediaAsset, MediaAssetStatus
    from app.utils import utcnow

    marker = "library:admin-seeded"
    with Session(engine) as session:
        if session.get(HomeSnapshot, marker) is not None:
            return 0
        have = set(session.exec(select(LibraryEntry.recording_id).where(LibraryEntry.user_id == ADMIN_ID)).all())
        ids = session.exec(
            select(MediaAsset.recording_id).where(
                MediaAsset.status == MediaAssetStatus.AVAILABLE,
                (MediaAsset.hidden_from_library.is_(None)) | (MediaAsset.hidden_from_library.is_(False)),  # type: ignore[union-attr]
            )
        ).all()
        added = 0
        for rid in ids:
            if rid not in have:
                session.add(LibraryEntry(user_id=ADMIN_ID, recording_id=rid))
                added += 1
        session.add(HomeSnapshot(key=marker, payload={"added": added}, generated_at=utcnow()))
        session.commit()
        return added
