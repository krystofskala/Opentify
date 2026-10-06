"""Podcasty: RSS, ochrana před vnitřními adresami, odběr a pozice."""
from __future__ import annotations

import asyncio

import pytest
from fastapi import HTTPException
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.routes.podcasts as routes
from app.models import PodcastEpisode, PodcastShow
from app.podcasts import feeds
from app.utils import utcnow

RSS = b"""<?xml version="1.0" encoding="UTF-8"?>
<rss version="2.0" xmlns:itunes="http://www.itunes.com/dtds/podcast-1.0.dtd">
<channel>
  <title>Vinohradsk\xc3\xa1 12</title>
  <itunes:author>\xc4\x8cesk\xc3\xbd rozhlas</itunes:author>
  <itunes:image href="https://example.org/cover.jpg"/>
  <description>&lt;p&gt;Zpravodajsk\xc3\xbd podcast&lt;/p&gt;</description>
  <item>
    <title>Star\xc5\xa1\xc3\xad d\xc3\xadl</title>
    <guid>ep-1</guid>
    <pubDate>Mon, 05 Oct 2026 00:01:00 +0200</pubDate>
    <itunes:duration>24:26</itunes:duration>
    <enclosure url="https://example.org/1.mp3" type="audio/mpeg"/>
  </item>
  <item>
    <title>Nov\xc4\x9bj\xc5\xa1\xc3\xad d\xc3\xadl</title>
    <guid>ep-2</guid>
    <pubDate>Tue, 06 Oct 2026 00:01:00 +0200</pubDate>
    <itunes:duration>1466</itunes:duration>
    <enclosure url="https://example.org/2.mp3" type="audio/mpeg"/>
  </item>
  <item><title>Bez zvuku</title></item>
</channel>
</rss>"""


def test_parse_feed_newest_first_with_durations():
    f = feeds.parse_feed(RSS)
    assert f["title"] == "Vinohradská 12"
    assert f["author"] == "Český rozhlas"
    assert f["artworkUrl"] == "https://example.org/cover.jpg"
    assert f["description"] == "Zpravodajský podcast"
    assert [e["guid"] for e in f["episodes"]] == ["ep-2", "ep-1"]  # bez enclosure vynechán
    assert f["episodes"][0]["durationMs"] == 1466000
    assert f["episodes"][1]["durationMs"] == (24 * 60 + 26) * 1000


@pytest.mark.parametrize(
    "url",
    ["http://127.0.0.1/x", "http://localhost/x", "http://10.0.0.1/x", "http://gluetun:8080/", "file:///etc/passwd",
     "ftp://example.org/x", "http://user:pw@example.org/"],
)
def test_internal_or_odd_urls_are_blocked(url):
    with pytest.raises(feeds.UnsafeUrl):
        asyncio.run(feeds.check_url(url))


@pytest.fixture
def session(monkeypatch):
    import app.podcasts.history as history

    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    monkeypatch.setattr(history, "engine", eng)
    with Session(eng) as s:
        s.add(PodcastShow(id="s1", feed_url="https://example.org/rss", title="V12", fetched_at=utcnow()))
        s.add(PodcastEpisode(id="e1", show_id="s1", guid="g1", title="Díl", audio_url="https://example.org/1.mp3"))
        s.commit()
        yield s


def test_subscribe_is_per_profile_and_idempotent(session):
    asyncio.run(routes.subscribe("s1", session=session, current=("me", "d")))
    asyncio.run(routes.subscribe("s1", session=session, current=("me", "d")))
    assert [s["id"] for s in routes.my_shows(session=session, current=("me", "d"))["shows"]] == ["s1"]
    assert routes.my_shows(session=session, current=("dad", "d"))["shows"] == []
    routes.unsubscribe("s1", session=session, current=("me", "d"))
    assert routes.my_shows(session=session, current=("me", "d"))["shows"] == []
    with pytest.raises(HTTPException):
        asyncio.run(routes.subscribe("nope", session=session, current=("me", "d")))


def test_progress_per_profile_and_in_progress_list(session):
    asyncio.run(routes.subscribe("s1", session=session, current=("me", "d")))
    routes.save_progress("e1", routes.ProgressIn(positionMs=90000), session=session, current=("me", "d"))
    new = asyncio.run(routes.new_episodes(session=session, current=("me", "d")))
    assert new["inProgress"][0]["positionMs"] == 90000
    assert new["episodes"][0]["id"] == "e1"
    assert asyncio.run(routes.new_episodes(session=session, current=("dad", "d")))["inProgress"] == []
    routes.save_progress("e1", routes.ProgressIn(positionMs=1000, finished=True), session=session, current=("me", "d"))
    assert asyncio.run(routes.new_episodes(session=session, current=("me", "d")))["inProgress"] == []
