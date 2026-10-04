"""Limit pokusů o přihlášení: počítá se hned (souběžné pokusy ho neobejdou),
úspěch čítač jména vynuluje. Falešný Redis -- živý se nedotkne."""
from __future__ import annotations

import uuid

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session

from app.auth import hash_password
from app.db import engine
from app.main import app
from app.models import AppUser

_RUN = uuid.uuid4().hex[:8]


class FakeRedis:
    def __init__(self):
        self.data: dict[str, int] = {}

    async def incr(self, key):
        self.data[key] = self.data.get(key, 0) + 1
        return self.data[key]

    async def expire(self, key, seconds):
        return True

    async def delete(self, key):
        self.data.pop(key, None)


@pytest.fixture
def fake(monkeypatch):
    import app.routes.auth as auth_routes

    r = FakeRedis()
    monkeypatch.setattr(auth_routes, "get_redis", lambda: r)
    monkeypatch.setenv("LOGIN_DEVICE_CODE", "0")
    monkeypatch.setattr("asyncio.sleep", _no_sleep)
    return r


async def _no_sleep(_s):
    return None


def test_ninth_failure_is_throttled_and_success_resets(fake):
    name = "thr-" + _RUN
    with Session(engine) as s:
        s.add(AppUser(name="T", username=name, password_hash=hash_password("spravne1")))
        s.commit()
    client = TestClient(app)
    for _ in range(7):
        assert client.post("/api/v1/auth/login", json={"username": name, "password": "spatne"}).status_code == 401
    # Úspěch vynuluje čítač jména.
    assert client.post("/api/v1/auth/login", json={"username": name, "password": "spravne1"}).status_code == 200
    for _ in range(8):
        assert client.post("/api/v1/auth/login", json={"username": name, "password": "spatne"}).status_code == 401
    assert client.post("/api/v1/auth/login", json={"username": name, "password": "spravne1"}).status_code == 429


def test_unknown_user_is_rejected_the_same_way(fake):
    client = TestClient(app)
    r = client.post("/api/v1/auth/login", json={"username": "nikdo-" + _RUN, "password": "x" * 8})
    assert r.status_code == 401
