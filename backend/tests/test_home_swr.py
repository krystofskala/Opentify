"""Domů: hned z uložené verze, souběžné první načtení = jedno sestavení."""
import asyncio

import app.catalog.cache as cache


class _FakeRedis:
    def __init__(self):
        self.data = {}

    async def get(self, k):
        return self.data.get(k)

    async def set(self, k, v, ex=None):
        self.data[k] = v


def test_concurrent_first_load_builds_once(monkeypatch):
    r = _FakeRedis()
    monkeypatch.setattr(cache, "get_redis", lambda: r)
    calls = []

    async def fetch():
        calls.append(1)
        await asyncio.sleep(0.05)
        return {"sections": [1]}

    async def main():
        res = await asyncio.gather(*(cache.cached_json_swr("home:u1", 300, fetch) for _ in range(10)))
        assert all(x == {"sections": [1]} for x in res)
        # druhé kolo: z uložené verze, nic se nesestavuje
        assert await cache.cached_json_swr("home:u1", 300, fetch) == {"sections": [1]}

    asyncio.run(main())
    assert len(calls) == 1
