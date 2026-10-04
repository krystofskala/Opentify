"""Všichni hlavní účinkující z Deezeru (ne jen první / dva) a jejich
zobrazení u skladby."""
import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.catalog.availability import recording_artist_name
from app.catalog.deezer_ingest import apply_credits, ingest_artist, main_credits
from app.models import Recording, Release


@pytest.fixture
def session():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        yield s


def _c(i, name, role="Main"):
    return {"id": i, "name": name, "role": role, "type": "artist"}


def test_all_main_contributors(session):
    credits = main_credits(session, [_c(1, "A"), _c(2, "B"), _c(3, "C", "Featured"), _c(4, "D")])
    assert [c["name"] for c in credits] == ["A", "B", "D"]
    assert "".join(c["name"] + c["join"] for c in credits) == "A, B & D"
    assert main_credits(session, [_c(1, "A")]) == []


def test_recording_and_album_credit_display(session):
    blake = ingest_artist(session, _c(10, "Norman Blake"))
    session.flush()
    album = Release(artist_id=blake.id, title="Norman Blake & Tony Rice 2", deezer_id="99")
    rec = Recording(title="Salt Creek", artist_id=blake.id, release_id=album.id)
    session.add_all([album, rec])
    session.flush()
    assert apply_credits(album, main_credits(session, [_c(10, "Norman Blake"), _c(11, "Tony Rice")]), album.artist_id)
    assert recording_artist_name(session, rec) == "Norman Blake & Tony Rice"
    # Skladba s vlastním obsazením má přednost.
    apply_credits(rec, main_credits(session, [_c(10, "Norman Blake"), _c(11, "Tony Rice"), _c(12, "Host")]), rec.artist_id)
    assert recording_artist_name(session, rec) == "Norman Blake, Tony Rice & Host"
