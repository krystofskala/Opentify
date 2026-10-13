"""Import historie (13. 10.): jeden na profil najednou, po doběhnutí smazat
spočítaný Wrapped a ohlásit `import.done`."""
from __future__ import annotations

import asyncio

import pytest
from fastapi import HTTPException

import app.events as events
import app.redis_bus as redis_bus
from app.catalog.cache import CACHE_PREFIX
from app.routes import library


class _FakeRedis:
    def __init__(self):
        self.d = {}

    async def set(self, k, v, nx=False, ex=None):
        if nx and k in self.d:
            return None
        self.d[k] = v
        return True

    async def delete(self, *keys):
        return sum(1 for k in keys if self.d.pop(k, None) is not None)

    async def scan_iter(self, pattern):
        prefix = pattern.rstrip("*")
        for k in list(self.d):
            if k.startswith(prefix):
                yield k


@pytest.fixture
def env(monkeypatch):
    r = _FakeRedis()
    sent = []
    monkeypatch.setattr(redis_bus, "get_redis", lambda: r)

    async def publish(user_id, event_type, payload):
        sent.append((user_id, event_type, payload))

    monkeypatch.setattr(events, "publish_event", publish)
    return r, sent


def test_druhy_import_behem_prvniho_odmitnut(env, monkeypatch):
    r, _ = env
    r.d["import:running:u1"] = "1"

    async def never(*a):
        raise AssertionError("import se nesmí spustit")

    monkeypatch.setattr(library, "_import_spotify", never)
    with pytest.raises(HTTPException) as exc:
        asyncio.run(library.import_spotify(None, None, ("u1", "d1")))
    assert exc.value.status_code == 409


def test_po_importu_historie_wrapped_smazan_a_oznameni(env, monkeypatch):
    r, sent = env
    r.d[f"{CACHE_PREFIX}wrapped:v4:u1:2025"] = "{}"
    r.d[f"{CACHE_PREFIX}wrapped:v4:u2:2025"] = "{}"

    async def fake(*a):
        return {"kind": "history", "listens": 10}

    monkeypatch.setattr(library, "_import_spotify", fake)
    out = asyncio.run(library.import_spotify(None, None, ("u1", "d1")))
    assert out["listens"] == 10
    assert f"{CACHE_PREFIX}wrapped:v4:u1:2025" not in r.d
    assert f"{CACHE_PREFIX}wrapped:v4:u2:2025" in r.d  # cizí profil zůstává
    assert "import:running:u1" not in r.d  # zámek uvolněn
    assert sent == [("u1", "import.done", {"platform": "spotify", "listens": 10})]


def test_zamek_uvolnen_i_po_chybe(env, monkeypatch):
    r, sent = env

    async def boom(*a):
        raise HTTPException(status_code=400, detail="špatný soubor")

    monkeypatch.setattr(library, "_import_spotify", boom)
    with pytest.raises(HTTPException):
        asyncio.run(library.import_spotify(None, None, ("u1", "d1")))
    assert "import:running:u1" not in r.d
    assert sent == []
