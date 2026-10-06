"""Profil › Historie: poslechy v appce, nejnovější první, bez importů a bez cizích profilů."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.models import Artist, Listen, Recording, Release
from app.routes.home import history


@pytest.fixture
def session():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        yield s


def _setup(session: Session) -> tuple[Recording, Recording]:
    artist = Artist(name="Dope Lemon", mbid="a-dl")
    release = Release(artist_id=artist.id, title="Golden Wolf", mbid="rg-gw")
    a = Recording(title="John Belushi", artist_id=artist.id, release_id=release.id, mbid="r-1")
    b = Recording(title="Sugarcat", artist_id=artist.id, release_id=release.id, mbid="r-2")
    session.add_all([artist, release, a, b])
    session.commit()
    return a, b


def test_history_newest_first_with_repeats_and_source(session):
    a, b = _setup(session)
    t0 = datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc)
    session.add_all([
        Listen(user_id="me", recording_id=a.id, played_at=t0, source="Denní mix 1"),
        Listen(user_id="me", recording_id=b.id, played_at=t0 + timedelta(minutes=5)),
        Listen(user_id="me", recording_id=a.id, played_at=t0 + timedelta(minutes=10), source="Golden Wolf"),
    ])
    session.commit()
    items = history(limit=100, session=session, current=("me", "dev"))["items"]
    assert [i["title"] for i in items] == ["John Belushi", "Sugarcat", "John Belushi"]
    assert items[0]["playedFrom"] == "Golden Wolf"
    assert items[2]["playedFrom"] == "Denní mix 1"
    assert items[0]["playedAt"].startswith("2026-10-05T12:10:00")


def test_history_skips_imports_other_profiles_and_respects_limit(session):
    a, b = _setup(session)
    t0 = datetime(2026, 10, 5, 12, 0, tzinfo=timezone.utc)
    session.add_all([
        Listen(user_id="me", recording_id=a.id, played_at=t0, source="spotify-history"),
        Listen(user_id="me", recording_id=a.id, played_at=t0 + timedelta(minutes=1), source="applemusic-history"),
        Listen(user_id="dad", recording_id=b.id, played_at=t0 + timedelta(minutes=2)),
        Listen(user_id="me", recording_id=b.id, played_at=t0 + timedelta(minutes=3)),
        Listen(user_id="me", recording_id=a.id, played_at=t0 + timedelta(minutes=4)),
    ])
    session.commit()
    items = history(limit=100, session=session, current=("me", "dev"))["items"]
    assert [i["title"] for i in items] == ["John Belushi", "Sugarcat"]
    assert len(history(limit=1, session=session, current=("me", "dev"))["items"]) == 1
    assert [i["title"] for i in history(limit=100, session=session, current=("dad", "dev"))["items"]] == ["Sugarcat"]
