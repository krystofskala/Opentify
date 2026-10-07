"""Podobní interpreti (bio): Deezer se ptá jen na ty, kdo nejsou v katalogu,
a jen tolik, kolik je potřeba; pořadí zůstává."""
from __future__ import annotations

import asyncio

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.catalog.lastfm as lastfm
from app.catalog.service import CatalogService
from app.models import Artist


class FakeDZ:
    def __init__(self, missing=()):
        self.asked: list[str] = []
        self.missing = set(missing)

    async def search_artist(self, name, limit=5, *, trust_name=True):
        self.asked.append(name)
        if name in self.missing:
            return []
        return [{"id": 1000 + int(name[1:]), "name": name, "picture_xl": None}]


def _run(found, dz, monkeypatch, known_mbids=()):
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)

    async def fake_similar(name, limit=20):
        return found

    monkeypatch.setattr(lastfm, "similar_artists", fake_similar)
    with Session(eng) as s:
        me = Artist(id="me", name="Me")
        s.add(me)
        for m in known_mbids:
            s.add(Artist(id=f"local-{m}", name=f"local {m}", mbid=m))
        s.commit()
        svc = CatalogService(s, None, dz)  # type: ignore[arg-type]
        return [a.name for a in asyncio.run(svc._lastfm_similar(me))]


def test_known_artists_skip_deezer_and_only_first_wave_is_searched(monkeypatch):
    found = [{"name": f"a{i}", "mbid": f"mb{i}" if i % 2 == 0 else None, "match": 1.0} for i in range(24)]
    dz = FakeDZ()
    names = _run(found, dz, monkeypatch, known_mbids=["mb0", "mb2"])
    assert names[:3] == ["local mb0", "a1", "local mb2"]
    assert len(names) == 12
    assert "a0" not in dz.asked and "a2" not in dz.asked
    assert max(int(n[1:]) for n in dz.asked) < 15  # druhá vlna nebyla potřeba


def test_second_wave_when_first_does_not_fill(monkeypatch):
    found = [{"name": f"a{i}", "mbid": None, "match": 1.0} for i in range(24)]
    dz = FakeDZ(missing={f"a{i}" for i in range(10)})
    names = _run(found, dz, monkeypatch)
    assert names == [f"a{i}" for i in range(10, 22)]
    assert "a20" in dz.asked
