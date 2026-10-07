"""#58: odkaz na kompilaci ze Spotify se nerozpadne na mini alba po interpretech."""
import asyncio

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

import app.library.spotify_link as link
from app.models import Playlist, Release


def _rows(album):
    return [
        ("Jelen", "Jelen", album, 200000), ("Mirai", "Holky z naší školky", album, 210000),
        ("Pokáč", "Vymlácený entry", album, 190000), ("Lenny", "Hell.o", album, 220000),
    ]


def test_detects_compilation():
    assert link.is_compilation("Various Artists", _rows("x")[:1])
    assert link.is_compilation(None, _rows("x"))
    # Album jednoho interpreta s hostem kompilace není.
    solo = [("Jelen", f"Song {i}", "Dál", 1) for i in range(8)] + [("Jelen", "Feat", "Dál", 1), ("Mirai", "X", "Dál", 1)]
    assert not link.is_compilation("Jelen", solo)


def test_compilation_link_makes_no_mini_albums(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)

    async def fake_fetch(text):
        return "album", "a" * 22, "Česká jednička 2026", "Various Artists", _rows("Česká jednička 2026"), None

    monkeypatch.setattr(link, "fetch_spotify_link", fake_fetch)
    with Session(e) as s:
        result = asyncio.run(link.import_spotify_link(s, "me", "https://open.spotify.com/album/" + "a" * 22))
        assert result.report.matched == 4
        assert s.exec(select(Release)).all() == []
        playlist = s.exec(select(Playlist)).one()
        assert playlist.description.startswith("Kompilace · Ze Spotify")
