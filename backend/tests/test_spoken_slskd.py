"""Audioknihy ze Soulseeku (záloha za SkTorrent): složky, průběh, stažení."""
from __future__ import annotations

import asyncio
import json

import httpx
import pytest
from fastapi import HTTPException
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.routes.spoken as routes
import app.spoken.slsk_books as slsk
from app.providers import SlskdProvider


class _FakeRedis:
    def __init__(self):
        self.data: dict[str, str] = {}

    async def set(self, key, value, ex=None, nx=False):
        self.data[key] = value

    async def get(self, key):
        return self.data.get(key)


def _resp(user, folder, sizes, free=True):
    return {
        "username": user, "hasFreeUploadSlot": free, "uploadSpeed": 1000, "queueLength": 0,
        "files": [{"filename": f"{folder}\\{i:02d}.mp3", "size": s} for i, s in enumerate(sizes)],
    }


@pytest.fixture
def redis(monkeypatch):
    r = _FakeRedis()
    monkeypatch.setattr(slsk, "get_redis", lambda: r)
    return r


def test_search_groups_folders_dedupes_and_skips_small(monkeypatch, redis):
    mb = 1024 * 1024
    responses = [
        _resp("anna", "Audiobooks\\Timothy Zahn\\Thrawn", [20 * mb] * 5),
        _resp("bob", "books\\Timothy Zahn\\Thrawn", [20 * mb] * 5, free=False),  # stejná kniha jinde
        _resp("cyril", "Music\\Thrawn OST", [5 * mb] * 3),  # malé = album, ne kniha
    ]

    async def fake_search_raw(self, query, cap_s=20.0):
        return responses

    monkeypatch.setattr(SlskdProvider, "search_raw", fake_search_raw)
    [book] = asyncio.run(slsk.search("thrawn"))
    assert book["seeders"] == 2 and book["freeSlot"] is True
    assert book["title"] == "Timothy Zahn – Thrawn"
    cached = asyncio.run(slsk.cached(book["ref"]))
    assert cached["user"] == "anna" and len(cached["files"]) == 5


def test_progress_uses_latest_attempt_per_file(monkeypatch):
    files = [{"filename": "a\\01.mp3", "size": 100}, {"filename": "a\\02.mp3", "size": 100}]
    payload = {"directories": [{"files": [
        {"filename": "a\\01.mp3", "state": "Completed, Errored", "bytesTransferred": 0, "requestedAt": "2026-10-06T07:00"},
        {"filename": "a\\01.mp3", "state": "Completed, Succeeded", "bytesTransferred": 100, "requestedAt": "2026-10-06T08:00"},
        {"filename": "a\\02.mp3", "state": "InProgress", "bytesTransferred": 50, "requestedAt": "2026-10-06T08:00"},
    ]}]}
    real = httpx.AsyncClient

    class _Client(real):  # type: ignore[misc, valid-type]
        def __init__(self, *a, **k):
            k["transport"] = httpx.MockTransport(lambda r: httpx.Response(200, json=payload))
            super().__init__(*a, **k)

    monkeypatch.setattr(slsk.httpx, "AsyncClient", _Client)
    share, state, retry, reason = asyncio.run(slsk.progress("anna", files))
    assert state == "downloading" and share == pytest.approx(0.75) and retry == [] and reason is None


def test_acquire_needs_fresh_search_result(monkeypatch, redis):
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        body = routes.AcquireIn(source="slskd", ref="slsk:abc", title="Timothy Zahn – Thrawn")
        with pytest.raises(HTTPException):
            asyncio.run(routes.acquire(body, session=s, current=("me", "d")))
        redis.data["spoken:slsk:slsk:abc"] = '{"user": "anna", "files": [{"filename": "x\\\\01.mp3", "size": 9}], "size": 9}'
        out = asyncio.run(routes.acquire(body, session=s, current=("me", "d")))
        assert out["status"] == "pending"
        again = asyncio.run(routes.acquire(body, session=s, current=("dad", "d")))
        assert again["id"] == out["id"]


def test_foreign_release_contents_before_download(redis):
    with pytest.raises(HTTPException):
        asyncio.run(routes.foreign_release_files("slsk:gone"))
    redis.data["spoken:slsk:slsk:abc"] = json.dumps({"user": "anna", "size": 13, "files": [
        {"filename": "Music\\Thrawn\\01.mp3", "size": 9}, {"filename": "Music\\Thrawn\\02.mp3", "size": 4}]})
    out = asyncio.run(routes.foreign_release_files("slsk:abc"))
    assert out == {"groups": [{"folder": "", "size": 13, "files": [
        {"index": 0, "name": "01.mp3", "size": 9}, {"index": 1, "name": "02.mp3", "size": 4}]}]}
