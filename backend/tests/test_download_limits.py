"""Limity stahování na člověka: hudba za hodinu/den, audioknihy za týden, admin bez limitu."""
import asyncio

import pytest
from fastapi import HTTPException
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.download_limits as dl
from app.models import AppUser, SpokenBook


class _FakeRedis:
    def __init__(self):
        self.d = {}

    async def get(self, k):
        return self.d.get(k)

    async def incr(self, k):
        self.d[k] = int(self.d.get(k, 0)) + 1
        return self.d[k]

    async def expire(self, k, ttl):
        pass


@pytest.fixture
def env(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    with Session(e) as s:
        s.add(AppUser(id="admin", name="Já", role="admin"))
        s.add(AppUser(id="pepa", name="Pepa", role="user"))
        s.commit()
    r = _FakeRedis()
    monkeypatch.setattr(dl, "engine", e)
    monkeypatch.setattr(dl, "get_redis", lambda: r)
    monkeypatch.setattr(dl, "notify", lambda *a, **k: True)
    return e


def test_music_limit_per_hour(env, monkeypatch):
    monkeypatch.setattr(dl, "MUSIC_PER_HOUR", 3)

    async def run():
        for _ in range(3):
            await dl.check_music("pepa")
            await dl.count_music("pepa")
        with pytest.raises(HTTPException) as e:
            await dl.check_music("pepa")
        assert e.value.status_code == 429
        for _ in range(10):  # admin bez limitu
            await dl.check_music("admin")
            await dl.count_music("admin")

    asyncio.run(run())


def test_books_big_release_needs_admin_and_weekly_cap(env):
    with pytest.raises(HTTPException) as e:
        dl.check_book("pepa", 6 * dl.GB)
    assert e.value.status_code == 403
    dl.check_book("admin", 30 * dl.GB)  # admin smí
    with Session(env) as s:
        s.add(SpokenBook(source_ref="a", release_title="x", title="x", size_bytes=18 * dl.GB, requested_by_user_id="pepa"))
        s.commit()
    dl.check_book("pepa", 1 * dl.GB)  # 19 GB -- ještě v limitu
    with pytest.raises(HTTPException) as e:
        dl.check_book("pepa", 3 * dl.GB)  # 21 GB
    assert e.value.status_code == 429
