"""Vícediskové album z Deezeru (Rubber Soul Super Deluxe, 7. 10.): pořadí
disk po disku a čísla průběžně, i když už skladby byly uložené s číslem z
disku."""
from __future__ import annotations

import asyncio

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

from app.models import Artist, Recording, Release


@pytest.fixture
def session():
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    with Session(e) as s:
        yield s


def _tracks():
    out = []
    for disk, titles in ((1, ["Drive My Car", "Norwegian Wood"]), (2, ["Wait (Take 3)", "Michelle (take 1)"])):
        for pos, title in enumerate(titles, start=1):
            out.append({"id": 1000 * disk + pos, "title": title, "duration": 150, "disk_number": disk,
                        "track_position": pos, "artist": {"id": 1, "name": "The Beatles"}})
    return out


class _DZ:
    async def album_tracks(self, _album_id):
        return _tracks()

    async def find_track_by_isrc(self, _isrc):
        return None


def test_multidisc_order_and_numbers(session):
    from app.catalog.service import CatalogService

    artist = Artist(name="The Beatles", deezer_id="1")
    session.add(artist)
    session.flush()
    release = Release(artist_id=artist.id, title="Rubber Soul (Super Deluxe)", deezer_id="99", release_type="album")
    session.add(release)
    session.flush()
    # Dřív uložená skladba disku 2 s číslem z disku (1).
    session.add(Recording(title="Wait (Take 3)", artist_id=artist.id, release_id=release.id, deezer_id="2001", track_number=1))
    session.commit()
    svc = CatalogService(session, None, _DZ())  # type: ignore[arg-type]
    out = asyncio.run(svc._deezer_release_tracks(release))
    assert [t.title for t in out] == ["Drive My Car", "Norwegian Wood", "Wait (Take 3)", "Michelle (take 1)"]
    nums = {r.title: r.track_number for r in session.exec(select(Recording)).all()}
    assert nums == {"Drive My Car": 1, "Norwegian Wood": 2, "Wait (Take 3)": 3, "Michelle (take 1)": 4}
    assert len(release.external_refs["tracklistIds"]) == 4
    assert release.external_refs["discs"] == [{"size": 2, "title": None}, {"size": 2, "title": None}]
    from app.catalog.service import _with_discs

    assert [t.disc_number for t in _with_discs(release, out)] == [1, 1, 2, 2]
