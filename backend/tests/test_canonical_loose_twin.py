"""Stažený soubor s překlepem v názvu se přiřadí ke skladbě kanonického
tracklistu; jiná verze (Acoustic / Live) ani jiná délka ne. DB v paměti."""
import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.catalog.canonical import find_referenced_twin
from app.models import MediaAsset, MediaAssetStatus, Recording


@pytest.fixture()
def session():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        yield s


def _file(session, title, ms, rid=None):
    rec = Recording(title=title, duration_ms=ms)
    session.add(rec)
    session.flush()
    session.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, waveform_duration_ms=ms))
    session.flush()
    return rec


def test_typo_and_remaster_tag_match(session):
    typo = _file(session, "Tanguska", 241_000)
    remaster = _file(session, "Come Together (Remastered 2009)", 259_000)
    rows = [typo, remaster]
    assert find_referenced_twin(session, rows, "Tunguska", 243_000, 3, set()) is typo
    assert find_referenced_twin(session, rows, "Come Together", 260_000, 1, set()) is remaster


def test_other_versions_and_lengths_stay_apart(session):
    acoustic = _file(session, "Little Numbers (Acoustic)", 180_000)
    live = _file(session, "White Blank Page (Live At Shepherd's Bush Empire, London)", 250_000)
    long_take = _file(session, "Tunguska", 300_000)
    rows = [acoustic, live, long_take]
    assert find_referenced_twin(session, rows, "Little Numbers", 182_000, 1, set()) is None
    assert find_referenced_twin(session, rows, "White Blank Page", 249_000, 2, set()) is None
    assert find_referenced_twin(session, rows, "Tunguska", 243_000, 3, set()) is None
