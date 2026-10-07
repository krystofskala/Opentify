"""Jen obal alba pro dlaždice: z DB hned, chybějící přes `fill_release`,
nikdy přes MusicBrainz detail. Úklid visících zámků cache při startu."""
from __future__ import annotations

import asyncio

import pytest
from fastapi import HTTPException
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.catalog.artwork as artwork
import app.db as db
from app.models import Artist, Release
from app.routes.catalog import get_release_cover


@pytest.fixture
def eng(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(db, "engine", e)
    with Session(e) as s:
        s.add(Artist(id="a", name="A"))
        s.add(Release(id="with", title="X", artist_id="a", images=["https://img/x.jpg"]))
        s.add(Release(id="without", title="Y", artist_id="a"))
        s.commit()
    return e


def test_cover_from_db_without_lookup(eng, monkeypatch):
    async def boom(*_a, **_k):
        raise AssertionError("obal je v DB, nic se nehledá")

    monkeypatch.setattr(artwork, "fill_release", boom)
    assert asyncio.run(get_release_cover("with", _current=None)) == {"images": ["https://img/x.jpg"]}


def test_missing_cover_is_filled(eng, monkeypatch):
    async def fill(release_id, force=False):
        with Session(eng) as s:
            r = s.get(Release, release_id)
            r.images = ["https://img/y.jpg"]
            s.add(r)
            s.commit()
        return True

    monkeypatch.setattr(artwork, "fill_release", fill)
    assert asyncio.run(get_release_cover("without", _current=None)) == {"images": ["https://img/y.jpg"]}
    with pytest.raises(HTTPException):
        asyncio.run(get_release_cover("nope", _current=None))


def test_clear_stale_locks(monkeypatch):
    from app.catalog import cache

    class FakeRedis:
        def __init__(self):
            self.keys = {"lock:vault:catalog:cache:artist-top:1", "lock:vault:catalog:cache:dz:x", "vault:catalog:cache:dz:x"}

        async def scan_iter(self, match, count):
            prefix = match.rstrip("*")
            for k in sorted(self.keys):
                if k.startswith(prefix):
                    yield k

        async def delete(self, key):
            self.keys.discard(key)
            return 1

    fake = FakeRedis()
    import app.redis_bus as bus

    monkeypatch.setattr(bus, "get_redis", lambda: fake)
    assert asyncio.run(cache.clear_stale_locks()) == 2
    assert fake.keys == {"vault:catalog:cache:dz:x"}


def test_discography_artist_is_fresh_from_db(eng, monkeypatch):
    import app.routes.catalog as cat

    async def stale(key, ttl, build):
        return {"artist": {"id": "a", "name": "A", "images": ["https://img/cizi.jpg"]}, "releases": [{"id": "with"}]}

    monkeypatch.setattr(cat, "cached_json_swr", stale)
    monkeypatch.setattr(cat, "engine", eng)
    with Session(eng) as s:
        a = s.get(Artist, "a")
        a.images = ["https://img/spravna.jpg"]
        s.add(a)
        s.commit()
    out = asyncio.run(cat.get_discography("a", None, _current=None))
    assert out["artist"]["images"] == ["https://img/spravna.jpg"]
    assert out["releases"] == [{"id": "with"}]


def test_stats_ignore_lastfm_autocorrect_to_other_artist(eng, monkeypatch):
    import app.catalog.lastfm as lf
    import app.routes.catalog as cat

    monkeypatch.setattr(db, "engine", eng)
    with Session(eng) as s:
        s.add(Artist(id="rh", name="Radio Head"))
        s.add(Artist(id="beat", name="Beatles"))
        s.commit()

    async def info(name):
        return {"name": "Radiohead" if name == "Radio Head" else "The Beatles", "listeners": 8_500_000, "playcount": 1, "tags": ["rock"]}

    async def top(name, limit=40):
        return []

    monkeypatch.setattr(lf, "artist_info", info)
    monkeypatch.setattr(lf, "top_albums", top)
    assert asyncio.run(cat.get_artist_stats("rh", _current=None))["listeners"] is None
    assert asyncio.run(cat.get_artist_stats("beat", _current=None))["listeners"] == 8_500_000


def test_stats_and_ampersand_is_same_artist(eng, monkeypatch):
    import app.catalog.lastfm as lf
    import app.routes.catalog as cat

    monkeypatch.setattr(db, "engine", eng)
    with Session(eng) as s:
        s.add(Artist(id="sg", name="Simon and Garfunkel"))
        s.commit()

    async def info(name):
        return {"name": "Simon & Garfunkel", "listeners": 5, "playcount": 1, "tags": []}

    async def top(name, limit=40):
        return []

    monkeypatch.setattr(lf, "artist_info", info)
    monkeypatch.setattr(lf, "top_albums", top)
    assert asyncio.run(cat.get_artist_stats("sg", _current=None))["listeners"] == 5
