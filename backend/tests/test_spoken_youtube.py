"""Audiokniha / rozhlasová hra z odkazu na YouTube."""
import asyncio

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.routes.spoken as routes
from app.models import SpokenBook
from app.spoken import youtube


@pytest.mark.parametrize("url", [
    "https://youtu.be/3vybAoOGvaQ",
    "https://www.youtube.com/watch?v=3vybAoOGvaQ&t=12",
    "https://youtube.com/watch?feature=share&v=3vybAoOGvaQ",
    "https://www.youtube.com/live/3vybAoOGvaQ?si=x",
])
def test_video_id(url):
    assert youtube.video_id(url) == "3vybAoOGvaQ"


def test_not_a_video():
    assert youtube.video_id("Saturnin Jirotka") is None
    assert youtube.video_id("https://www.youtube.com/@rozhlas") is None


def test_summary_chapters_and_size():
    s = youtube.summary({"id": "x", "title": " Neuromancer ", "uploader": "Kanál", "duration": 3600,
                         "chapters": [{"title": "Úvod", "start_time": 0}, {"title": "1", "start_time": 90.5}]})
    assert s["title"] == "Neuromancer" and s["sizeBytes"] == 3600 * 16_000
    assert s["chapters"][1] == {"title": "1", "startMs": 90500}


def test_search_with_link_and_acquire(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)

    async def fake_info(vid):
        return {"id": vid, "title": "Neuromancer – audiokniha", "uploader": "K", "durationS": 3720, "sizeBytes": 1, "chapters": []}

    monkeypatch.setattr(youtube, "info", fake_info)
    with Session(e) as s:
        out = asyncio.run(routes.search("https://youtu.be/3vybAoOGvaQ", session=s))
        [rel] = out["releases"]
        assert rel["source"] == "youtube" and rel["durationText"] == "1 h 2 min"
        body = routes.AcquireIn(source="youtube", ref=rel["ref"], title=rel["title"], sizeBytes=1)
        book = asyncio.run(routes.acquire_now(body, s, "me"))
        row = s.get(SpokenBook, book["id"])
        assert row.source == "youtube" and row.source_ref == "yt:3vybAoOGvaQ" and row.source_files == {"video": "3vybAoOGvaQ"}
        # Stejné video podruhé = stejná kniha.
        assert asyncio.run(routes.acquire_now(body, s, "me"))["id"] == book["id"]
        assert asyncio.run(routes.search_foreign("https://youtu.be/3vybAoOGvaQ", session=s)) == {"releases": []}


def test_kind_from_title():
    from app.spoken.acquire import guess_kind

    assert guess_kind("J.R.R. Tolkien: Pan prstenov - rozhlasová hra(2003)(SK)[MP3]") == "drama"
    assert guess_kind("Krakatit (dramatizace, 1963)") == "drama"
    assert guess_kind("Hra o trůny - George R. R. Martin") == "book"
    assert guess_kind("Saturnin - Zdeněk Jirotka (2010)") == "book"
