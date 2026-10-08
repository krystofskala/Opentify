"""Nálada skladby: štítek Last.fm, playlist nálady Deezeru, rozbor zvuku
(veto i doklad); interpret sám nestačí."""

import asyncio
import uuid

from sqlmodel import Session

from app.catalog import lastfm
from app.db import engine
from app.home import mood_tracks
from app.models import Artist, Recording, TrackFeatures


def _track(title: str, energy: float | None = None, deezer_id: str | None = None) -> str:
    with Session(engine) as s:
        a = Artist(name=f"Mood Artist {uuid.uuid4().hex[:6]}")
        s.add(a)
        s.flush()
        r = Recording(title=title, artist_id=a.id, deezer_id=deezer_id)
        s.add(r)
        s.flush()
        if energy is not None:
            s.add(TrackFeatures(recording_id=r.id, energy=energy, bpm=128, bpm_confidence=0.8))
        s.commit()
        return r.id


def test_track_level_mood_evidence(monkeypatch):
    tagged = _track("Sad Song")
    in_playlist = _track("Deezer Pick", deezer_id="dz-" + uuid.uuid4().hex[:6])
    loud_ballad = _track("Shouty", energy=0.95)
    nothing = _track("Plain")

    async def fake_tags(artist, title, *, cached_only=False):
        return [("sad", 100), ("indie", 40)] if title in ("Sad Song", "Shouty") else []

    async def fake_chart(tag, limit=50):
        return [{"artist": "Chart Artist", "title": "Charted Tune (Remastered)"}] if tag == "sad" else []

    monkeypatch.setattr(lastfm, "track_top_tags", fake_tags)
    monkeypatch.setattr(lastfm, "tag_top_tracks", fake_chart)
    with Session(engine) as s:
        ca = Artist(name="Chart Artist")
        s.add(ca)
        s.flush()
        charted_rec = Recording(title="Charted Tune", artist_id=ca.id)
        s.add(charted_rec)
        s.commit()
        charted = charted_rec.id
    with Session(engine) as s:
        dz = s.get(Recording, in_playlist).deezer_id
    ev = asyncio.run(mood_tracks.evidence([tagged, in_playlist, loud_ballad, nothing, charted], "sad", {dz}))
    assert ev[charted] >= 1  # v žebříčku štítku „sad“ na Last.fm (podle jména)
    assert ev[tagged] >= 1
    assert ev[in_playlist] >= 1
    assert ev[loud_ballad] < 0  # štítek „sad“, ale zvuk je energie 0,95 -> veto
    assert ev[nothing] == 0


def test_audio_alone_proves_sleep_only():
    assert not mood_tracks.audio_evidence("workout", 0.9, 130)  # energie necítí „cvičení“
    assert mood_tracks.audio_evidence("sleep", 0.1, None)
    assert not mood_tracks.audio_evidence("sleep", 0.1, 140)
    assert not mood_tracks.audio_evidence("party", 0.9, 128)
    assert mood_tracks.audio_veto("workout", 0.2, None)
    assert mood_tracks.audio_veto("sleep", 0.6, None)
    assert not mood_tracks.audio_veto("romance", 0.9, None)
