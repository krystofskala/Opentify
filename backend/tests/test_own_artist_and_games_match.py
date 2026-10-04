"""Vlastní interpret (Kontrast) se nepáruje podle jména s cizími zdroji,
/browse/search-tags nepohltí `/{category_id}`, párování herních soundtracků
(římské číslice, slepené číslo dílu, Valve)."""
from __future__ import annotations

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.models import Artist


@pytest.fixture
def session():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        yield s


# --- /browse/search-tags ----------------------------------------------------


def test_browse_search_tags_resolves_to_its_endpoint():
    from starlette.routing import Match

    from app.routes.browse import browse_router, search_tags

    scope = {"type": "http", "path": "/browse/search-tags", "method": "GET"}
    route = next(r for r in browse_router.routes if r.matches(scope)[0] == Match.FULL)
    assert route.endpoint is search_tags


# --- vlastní interpret ------------------------------------------------------


def _kontrast(session: Session) -> Artist:
    own = Artist(name="Kontrast", mbid="own:x1", deezer_id="own:x1", external_refs={"ownArtist": True})
    session.add(own)
    session.commit()
    return own


def test_import_does_not_attach_to_own_artist(session):
    from app.library.matching import find_or_create_artist

    own = _kontrast(session)
    foreign = find_or_create_artist(session, "Kontrast")
    assert foreign.id != own.id
    # Další import už najde tu cizí, ne vlastního.
    assert find_or_create_artist(session, "Kontrast").id == foreign.id


def test_local_scan_keeps_own_artist(session):
    from app.library.matching import find_or_create_artist

    own = _kontrast(session)
    session.add(Artist(name="Kontrast", mbid="mb-foreign"))
    session.commit()
    assert find_or_create_artist(session, "Kontrast", allow_own=True).id == own.id


def test_is_own_artist():
    from app.catalog.identity import is_own_artist

    assert is_own_artist(Artist(name="Kontrast", mbid="own:a"))
    assert is_own_artist(Artist(name="Kontrast", external_refs={"ownArtist": True}))
    assert not is_own_artist(Artist(name="Kontrast", mbid="mb-1"))
    assert not is_own_artist(None)


# --- herní soundtracky ------------------------------------------------------


def _match(game: str, album: str, sequel=None) -> bool:
    from app.games import _SEQUEL, _same_work, _words

    want = [w for w in _words(game) if w not in ("the", "of", "a", "and")]
    return _same_work(want, set(_words(game)), _words(album), frozenset(sequel or _SEQUEL))


def test_roman_numerals_match_arabic():
    assert _match("Dark Souls III", "Dark Souls 3 Original Soundtrack")
    assert _match("Dark Souls 3", "DARK SOULS III Original Soundtrack")


def test_sequel_still_rejected():
    assert not _match("Dark Souls III", "Dark Souls II Original Soundtrack")
    assert not _match("Dark Souls 3", "Dark Souls 2 Original Soundtrack")
    assert not _match("Dark Souls", "Dark Souls III Original Soundtrack")


def test_glued_title_digit_split():
    from app.games import _words

    assert _words("SILENT HILL2 Original Soundtrack")[:3] == ["silent", "hill", "2"]
    assert _match("Silent Hill 2", "SILENT HILL2 Original Soundtrack")
    assert not _match("Silent Hill 3", "SILENT HILL2 Original Soundtrack")


def test_valve_is_a_label():
    from app.games import _LABELS

    assert "valve" in _LABELS
