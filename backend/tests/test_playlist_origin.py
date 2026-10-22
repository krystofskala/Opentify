"""Zápis původu skladby v mixu (OP-ALG1 B): PlaylistItem.origin."""
import uuid
from datetime import timedelta

from sqlmodel import Session, select

from app.db import engine
from app.home import generators as g
from app.models import Artist, PlaylistItem, PlaylistKind, Recording


def test_save_playlist_writes_origins():
    run = uuid.uuid4().hex[:8]
    with Session(engine) as s:
        artist = Artist(name="Origin Artist " + run)
        s.add(artist)
        s.flush()
        recs = [Recording(title=f"Origin {run} {i}", artist_id=artist.id, duration_ms=200_000) for i in range(3)]
        s.add_all(recs)
        s.commit()
        ids = [r.id for r in recs]
    pid = g._save_playlist(
        owner="origin-" + run, source="personal:test-origin", title="t", description=None,
        kind=PlaylistKind.PERSONAL_MIX, section="mixes", recording_ids=ids, cover_urls=[],
        ttl=timedelta(days=1), origins={ids[0]: "known", ids[1]: "new:lastfm"},
    )
    with Session(engine) as s:
        got = {i.recording_id: i.origin for i in s.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == pid)).all()}
    assert got == {ids[0]: "known", ids[1]: "new:lastfm", ids[2]: None}
