"""Single-flight v `cached_json`: studené sestavení běží jednou, souběžní
volající dostanou stejný výsledek (load test: stránka kategorie 20-30 s
se stavěla souběžně pro každého)."""
from __future__ import annotations

import asyncio

from app.catalog import cache


class FakeRedis:
    def __init__(self) -> None:
        self.data: dict[str, str] = {}

    async def get(self, key):
        return self.data.get(key)

    async def set(self, key, value, ex=None, nx=False):
        if nx and key in self.data:
            return None
        self.data[key] = value
        return True

    async def exists(self, key):
        return int(key in self.data)

    async def delete(self, key):
        self.data.pop(key, None)


def test_concurrent_callers_share_one_build(monkeypatch):
    fake = FakeRedis()
    monkeypatch.setattr(cache, "get_redis", lambda: fake)
    calls = 0

    async def build():
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.05)
        return {"n": 42}

    async def run():
        return await asyncio.gather(*(cache.cached_json("cat:x", 60, build) for _ in range(8)))

    results = asyncio.run(run())
    assert calls == 1
    assert all(r == {"n": 42} for r in results)
    assert not cache._inflight
    assert not any(k.startswith("lock:") for k in fake.data)


def test_failed_build_reaches_waiters_and_next_call_retries(monkeypatch):
    fake = FakeRedis()
    monkeypatch.setattr(cache, "get_redis", lambda: fake)
    calls = 0

    async def build():
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.02)
        if calls == 1:
            raise RuntimeError("zdroj spadl")
        return {"ok": True}

    async def run():
        first = await asyncio.gather(*(cache.cached_json("cat:y", 60, build) for _ in range(3)), return_exceptions=True)
        second = await cache.cached_json("cat:y", 60, build)
        return first, second

    first, second = asyncio.run(run())
    assert all(isinstance(r, RuntimeError) for r in first)
    assert second == {"ok": True}
    assert calls == 2


def test_cancelled_leader_does_not_cancel_waiters(monkeypatch):
    fake = FakeRedis()
    monkeypatch.setattr(cache, "get_redis", lambda: fake)
    calls = 0

    async def build():
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.05)
        return {"v": calls}

    async def run():
        leader = asyncio.create_task(cache.cached_json("cat:z", 60, build))
        await asyncio.sleep(0.01)
        waiter = asyncio.create_task(cache.cached_json("cat:z", 60, build))
        await asyncio.sleep(0.01)
        leader.cancel()
        return await waiter

    assert asyncio.run(run()) == {"v": 2}


def test_waits_for_other_process_holding_redis_lock(monkeypatch):
    fake = FakeRedis()
    monkeypatch.setattr(cache, "get_redis", lambda: fake)
    key = cache.CACHE_PREFIX + "cat:w"
    fake.data["lock:" + key] = "1"  # sestavuje jiný proces (worker)

    async def build():
        raise AssertionError("nemělo se stavět podruhé")

    async def other_process():
        await asyncio.sleep(0.1)
        fake.data[key] = '{"from": "worker"}'
        fake.data.pop("lock:" + key)

    async def run():
        asyncio.create_task(other_process())
        return await cache.cached_json("cat:w", 60, build)

    assert asyncio.run(run()) == {"from": "worker"}
