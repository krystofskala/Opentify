"""MB skupina alba, které už je v katalogu z Deezeru, převezme deezerový
řádek místo založení dvojčete (živě: Texican Badman chybělo v diskografii)."""
from __future__ import annotations

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.catalog.upsert import upsert_release
from app.models import Artist, Release


@pytest.fixture
def session():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        yield s


def test_mb_group_adopts_same_release_from_deezer(session):
    artist = Artist(name="C418")
    dz = Release(artist_id=artist.id, title="Minecraft – Volume Alpha", deezer_id="1", release_type="album", release_date="2011-03-04")
    session.add_all([artist, dz])
    session.commit()
    rel = upsert_release(session, mbid="mb-1", artist_id=artist.id, title="Minecraft – Volume Alpha", release_date="2011-03-04", release_type="album")
    assert rel.id == dz.id and rel.mbid == "mb-1" and rel.deezer_id == "1"


def test_reissue_with_other_year_stays_separate(session):
    # Texican Badman: MB 1981, Deezer 2019 s jinou "Sweet Melinda" -- nespojovat.
    artist = Artist(name="Peter Rowan")
    dz = Release(artist_id=artist.id, title="Texican Badman", deezer_id="118814742", release_type="album", release_date="2019-11-19")
    session.add_all([artist, dz])
    session.commit()
    rel = upsert_release(session, mbid="mb-1", artist_id=artist.id, title="Texican Badman", release_date="1981", release_type="album")
    assert rel.id != dz.id and dz.mbid is None


def test_single_does_not_adopt_album(session):
    artist = Artist(name="Radiohead")
    album = Release(artist_id=artist.id, title="The Bends", deezer_id="1", release_type="album")
    session.add_all([artist, album])
    session.commit()
    rel = upsert_release(session, mbid="mb-s", artist_id=artist.id, title="The Bends", release_date="1996", release_type="single")
    assert rel.id != album.id


def test_own_and_imported_are_left_alone(session):
    artist = Artist(name="X")
    yt = Release(artist_id=artist.id, title="A", deezer_id="5", release_type="album", external_refs={"source": "youtube"})
    session.add_all([artist, yt])
    session.commit()
    rel = upsert_release(session, mbid="mb-a", artist_id=artist.id, title="A", release_date=None, release_type="album")
    assert rel.id != yt.id
