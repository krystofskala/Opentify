"""Jedno video (DJ mix, set) jako playlist: skladby z kapitol / popisu."""

import asyncio
import uuid

from sqlmodel import Session, select

from app.db import engine
from app.library import youtube_link as yl
from app.models import PlaylistItem, Recording


def test_tracklist_from_description_and_chapters():
    desc = (
        "Tracklist:\n00:00 Intro\n00:00 Bob Seger - Old Time Rock n Roll\n3:12 Chuck Berry – Johnny B. Goode\n"
        "1. 06:01 Elvis Presley - Hound Dog\nElvis Presley - Jailhouse Rock 9:30\nfollow me 12:00"
    )
    rows = yl.tracklist({"description": desc, "duration": 720})
    assert [(r["artist"], r["title"]) for r in rows] == [
        ("Bob Seger", "Old Time Rock n Roll"),
        ("Chuck Berry", "Johnny B. Goode"),
        ("Elvis Presley", "Hound Dog"),
        ("Elvis Presley", "Jailhouse Rock"),
    ]
    assert rows[0]["duration"] == 192
    chapters = [{"start_time": t, "title": f"A{t} - B{t}"} for t in (0, 60, 120)]
    assert len(yl.tracklist({"chapters": chapters, "duration": 200})) == 3
    # Jeden čas v popisu není tracklist.
    assert yl.tracklist({"description": "just a video 0:30"}) == []


def test_single_video_imports_as_playlist_of_its_tracks(monkeypatch):
    user = "yt-tl-" + uuid.uuid4().hex[:6]
    tag = uuid.uuid4().hex[:6]
    tracks = [{"artist": f"Artist {tag} {i}", "title": f"Song {tag} {i}", "duration": 180} for i in range(3)]

    async def fake_inspect(_text):
        return {
            "url": "https://www.youtube.com/watch?v=abcdefghijk", "source": "youtube", "kind": "video",
            "title": "Rock n Roll Mix", "channel": "DJ Jerome", "artist": "DJ Jerome", "thumbnail": None,
            "videos": [{"id": "abcdefghijk", "title": "Rock n Roll Mix", "artist": "DJ Jerome", "duration": 3600}],
            "tracklist": tracks,
        }

    async def no_match(*_a, **_k):
        return None

    monkeypatch.setattr(yl, "inspect_youtube_link", fake_inspect)
    monkeypatch.setattr(yl, "_match_catalog", no_match)
    with Session(engine) as s:
        out = asyncio.run(yl.import_youtube_link(s, user, "x", kind="playlist"))
        assert out["kind"] == "playlist" and out["count"] == 3
        items = s.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == out["playlistId"]).order_by(PlaylistItem.position)).all()
        titles = [s.get(Recording, i.recording_id).title for i in items]
        assert titles == [t["title"] for t in tracks]
        # Skladby nemají vlastní video -- nesmí dostat odkaz na celý mix.
        assert all("youtubeId" not in (s.get(Recording, i.recording_id).external_refs or {}) for i in items)
