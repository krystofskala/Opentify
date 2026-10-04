"""Opakovaný upsert beze změny nesmí zapisovat (dřív každé načtení tracklistu
přepsalo `updated_at` všech skladeb -> zámek SQLite při každém GET)."""
from __future__ import annotations

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.catalog.upsert import upsert_artist, upsert_recording, upsert_release


def test_unchanged_upsert_keeps_updated_at():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        artist = upsert_artist(s, mbid="a-1", name="Opeth", sort_name="Opeth")
        rel = upsert_release(s, mbid="r-1", artist_id=artist.id, title="Damnation", release_date="2003", release_type="album")
        kw = dict(mbid="t-1", release_id=rel.id, artist_id=artist.id, title="Windowpane", duration_ms=464000, isrc=None, track_number=1)
        rec = upsert_recording(s, **kw)
        stamps = (artist.updated_at, rel.updated_at, rec.updated_at)

        artist2 = upsert_artist(s, mbid="a-1", name="Opeth", sort_name="Opeth")
        rel2 = upsert_release(s, mbid="r-1", artist_id=artist.id, title="Damnation", release_date=None, release_type="album")
        rec2 = upsert_recording(s, **kw)
        assert (artist2.updated_at, rel2.updated_at, rec2.updated_at) == stamps

        rec3 = upsert_recording(s, **{**kw, "title": "Windowpane (Remastered)"})
        assert rec3.title == "Windowpane (Remastered)"
        assert rec3.updated_at != stamps[2]
