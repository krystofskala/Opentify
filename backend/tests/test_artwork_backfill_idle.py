"""Smyčka doplňování obrázků nesmí točit naprázdno (API na 100 % CPU)."""

import asyncio

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.catalog.artwork as artwork
import app.catalog.identity as identity
from app.models import Artist


@pytest.fixture
def eng(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(artwork, "engine", e)
    monkeypatch.setattr(identity, "engine", e)
    return e


def test_own_artist_is_marked_checked_and_leaves_pending(eng, monkeypatch):
    async def never(*a, **k):
        raise AssertionError("vlastní interpret se podle jména nehledá")

    monkeypatch.setattr(artwork, "resolve_artist_image", never)
    with Session(eng) as s:
        s.add(Artist(id="kontrast", name="Kontrast", mbid="own:kontrast"))
        s.commit()
    assert "kontrast" in artwork._pending(40)[1]
    assert asyncio.run(artwork.fill_artist("kontrast")) is False
    assert "kontrast" not in artwork._pending(40)[1]


def test_recently_attempted_items_are_skipped(eng):
    with Session(eng) as s:
        s.add(Artist(id="a1", name="Někdo"))
        s.add(Artist(id="a2", name="Jiný"))
        s.commit()
    assert artwork._pending(40, frozenset({"a1"}))[1] == ["a2"]
