"""Podcasty ze Spotify historie: import, párování názvu, doposlouchané epizody."""
from __future__ import annotations

import io
import json
import zipfile

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

import app.podcasts.history as history
from app.models import PodcastEpisode, PodcastNameMatch, PodcastProgress, PodcastShow


def _zip(rows: list[dict]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("Spotify Extended Streaming History/Streaming_History_Audio_2025.json", json.dumps(rows))
    return buf.getvalue()


ROWS = [
    {"ts": "2025-03-01T10:00:00Z", "ms_played": 600000, "episode_show_name": "Buchty", "episode_name": "Díl 1"},
    {"ts": "2025-03-02T10:00:00Z", "ms_played": 1200000, "episode_show_name": "Buchty", "episode_name": "Díl 1"},
    {"ts": "2025-03-03T10:00:00Z", "ms_played": 60000, "episode_show_name": "Buchty", "episode_name": "Díl 2"},
    {"ts": "2025-03-04T10:00:00Z", "ms_played": 200000, "master_metadata_track_name": "Song",
     "master_metadata_album_artist_name": "Band"},
]


@pytest.fixture
def eng(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(history, "engine", e)
    return e


def test_import_sums_per_episode_and_replaces_previous(eng):
    rows = history.read_spotify_zip(_zip(ROWS))
    assert len(rows) == 3  # hudba vynechána
    assert history.import_rows("me", rows) == {"podcastShows": 1, "podcastEpisodes": 2}
    assert history.import_rows("me", rows) == {"podcastShows": 1, "podcastEpisodes": 2}  # nic se nezdvojí
    [show] = history.overview("me")
    assert show["name"] == "Buchty"
    assert show["ms"] == 1860000
    assert show["episodes"] == 2
    assert history.overview("dad") == []


def test_best_match_by_folded_title():
    results = [{"title": "Buchty a koláče"}, {"title": "BUCHTY"}, {"title": "Buchty podcast"}]
    assert history._best("Buchty", results)["title"] == "BUCHTY"
    assert history._best("Vinohradská 12", [{"title": "Vinohradska 12"}])["title"] == "Vinohradska 12"
    assert history._best("Buchty", [{"title": "Buchty podcast"}])["title"] == "Buchty podcast"
    assert history._best("Buchty", [{"title": "Úplně jiný pořad"}]) is None


def test_finished_episodes_marked_only_without_existing_progress(eng):
    history.import_rows("me", history.read_spotify_zip(_zip(ROWS)))
    with Session(eng) as s:
        s.add(PodcastShow(id="s1", feed_url="https://example.org/rss", title="Buchty (podcast)"))
        s.add(PodcastNameMatch(name="Buchty", feed_url="https://example.org/rss", title="Buchty (podcast)"))
        s.add(PodcastEpisode(id="e1", show_id="s1", guid="1", title="DÍL 1", audio_url="x", duration_ms=1800000))
        s.add(PodcastEpisode(id="e2", show_id="s1", guid="2", title="Díl 2", audio_url="x", duration_ms=1800000))
        s.add(PodcastEpisode(id="e3", show_id="s1", guid="3", title="Díl 3", audio_url="x", duration_ms=1800000))
        s.commit()
    assert history.mark_finished_from_history("me", "s1") == 1  # díl 1 (30 min z 30), díl 2 jen minuta
    assert history.mark_finished_from_history("me", "s1") == 0  # už má pozici
    with Session(eng) as s:
        [p] = s.exec(select(PodcastProgress)).all()
        assert (p.episode_id, p.finished) == ("e1", True)
    assert history.mark_finished_from_history("dad", "s1") == 0
