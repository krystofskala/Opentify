"""Populární skladby interpreta: album z Last.fm a Deezer se dohledávají
pro každou skladbu zvlášť (souběžně), pořadí a přesná verze zůstávají."""
from __future__ import annotations

import asyncio

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.catalog.lastfm as lastfm
import app.catalog.top_tracks as tt
from app.models import Artist, Recording, Release

TITLES = ["Heathens", "Stressed Out", "Ride", "Car Radio", "Chlorine", "Jumpsuit"]
ALBUMS = {"Heathens": "Suicide Squad", "Stressed Out": "Blurryface", "Ride": "Blurryface",
          "Car Radio": "Vessel", "Chlorine": "Trench", "Jumpsuit": "Trench"}


class FakeDeezer:
    def __init__(self):
        self.queries = []

    async def search(self, q, limit):
        self.queries.append(q)
        title = q.split('track:"')[1].split('"')[0] if 'track:"' in q else None
        if title is None:
            return {"data": []}
        return {"data": [
            {"id": hash((title, "live")) % 10**6, "title": title, "artist": {"id": 1, "name": "twenty one pilots"},
             "album": {"id": 2, "title": "Live In Mexico City"}},
            {"id": hash(title) % 10**6, "title": title, "artist": {"id": 1, "name": "twenty one pilots"},
             "album": {"id": 3, "title": ALBUMS[title]}},
        ]}

    async def find_track(self, artist, title, loose=None):
        return None

    async def search_artist(self, name, trust_name=True):
        return [{"id": 1, "name": "twenty one pilots"}]

    async def artist_top(self, artist_id, limit):
        # Chlorine z Trench je mezi top skladbami -> nehledá se.
        return [{"id": 7, "title": "Chlorine", "artist": {"id": 1, "name": "twenty one pilots"},
                 "album": {"id": 4, "title": "Trench"}},
                {"id": 8, "title": "Car Radio", "artist": {"id": 1, "name": "twenty one pilots"},
                 "album": {"id": 5, "title": "Car Radio (Live)"}}]


def test_each_track_resolves_on_its_own_and_keeps_exact_version(monkeypatch):
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        s.add(Artist(id="a", name="twenty one pilots"))
        s.add(Release(id="r-blurry", title="Blurryface", artist_id="a"))
        s.add(Recording(id="local-ride", title="Ride", artist_id="a", release_id="r-blurry"))
        s.commit()
    monkeypatch.setattr(tt, "engine", eng)

    async def fake_top(name):
        return [{"title": t, "listens": 1000 - i} for i, t in enumerate(TITLES)]

    started: list[str] = []

    async def fake_album(artist, title):
        started.append(title)
        # Pozdější skladby odpoví dřív -- pořadí výsledku se nesmí změnit.
        await asyncio.sleep(0.01 * (len(TITLES) - TITLES.index(title)))
        return ALBUMS[title]

    dz = FakeDeezer()
    monkeypatch.setattr(tt, "_lastfm_top", fake_top)
    monkeypatch.setattr(lastfm, "track_album", fake_album)
    monkeypatch.setattr(tt, "get_deezer_client", lambda: dz)

    def fake_ingest(session, track):
        rec = Recording(id=f"dz-{track['title']}-{track['album']['title']}", title=track["title"], artist_id="a")
        session.add(rec)
        return rec

    monkeypatch.setattr(tt, "ingest_track_with_context", fake_ingest)
    out = asyncio.run(tt._ids_and_counts("a"))
    assert [o["id"] for o in out] == [
        "dz-Heathens-Suicide Squad", "dz-Stressed Out-Blurryface", "local-ride",
        "dz-Car Radio-Vessel", "dz-Chlorine-Trench", "dz-Jumpsuit-Trench",
    ]
    assert [o["listens"] for o in out] == [1000, 999, 998, 997, 996, 995]
    assert all(o["source"] == "lastfm" for o in out)
    assert sorted(started) == sorted(TITLES)
    # Ride je v katalogu (stejné album) -> na Deezer se pro ni nešlo.
    assert not any('track:"Ride"' in q for q in dz.queries)
    # Chlorine se vzala z top skladeb Deezeru, Car Radio ne (jiné album).
    assert not any('track:"Chlorine"' in q for q in dz.queries)
    assert any('track:"Car Radio"' in q for q in dz.queries)
