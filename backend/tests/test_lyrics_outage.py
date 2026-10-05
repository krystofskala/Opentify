"""Výpadek LRCLIB (503) nesmí vypadat jako "text neexistuje": krátký výpadek
se zkusí znovu, dlouhý = LyricsSourceDown (route 503, appka zkusí znovu),
nic se neuloží jako "nenalezeno"."""
import asyncio
import uuid

import httpx
import pytest

from app import lyrics_service as ls


class _Resp:
    def __init__(self, status, payload=None):
        self.status_code = status
        self._payload = payload if payload is not None else []

    def raise_for_status(self):
        if self.status_code >= 400:
            raise httpx.HTTPStatusError("x", request=httpx.Request("GET", "http://x"), response=httpx.Response(self.status_code))

    def json(self):
        return self._payload


_CACHE: dict = {}


async def _memory_cache(key, ttl, fetch, is_empty=None):
    """Mezipaměť v paměti místo Redisu (CI Redis nemá); výjimka z `fetch`
    se neuloží, stejně jako v `cached_json`."""
    if key not in _CACHE:
        _CACHE[key] = await fetch()
    return _CACHE[key]


def _fake(monkeypatch, statuses):
    calls = []
    monkeypatch.setattr(ls, "cached_json", _memory_cache)

    async def get(path, params=None):
        calls.append(params)
        status = statuses.pop(0) if statuses else 200
        body = [{"id": 1, "syncedLyrics": "[00:01.00]ahoj", "plainLyrics": "ahoj", "duration": 200}] if status == 200 else None
        return _Resp(status, body)

    monkeypatch.setattr(ls._client, "get", get)
    monkeypatch.setattr(ls, "_RETRY_DELAYS_S", (0, 0))
    monkeypatch.setattr(ls, "_netease_client", lambda: None)
    return calls


def test_short_outage_is_retried(monkeypatch):
    calls = _fake(monkeypatch, [503, 503])
    result = asyncio.run(ls.fetch_lyrics(track_name="Píseň " + uuid.uuid4().hex, artist_name="Někdo", album_name=None, duration_s=200))
    assert result and result["synced"] == "[00:01.00]ahoj"
    assert len(calls) == 3


def test_long_outage_is_not_cached_as_missing(monkeypatch):
    _fake(monkeypatch, [503] * 20)

    async def no_ovh(*a):
        return None

    monkeypatch.setattr(ls, "_lyrics_ovh", no_ovh)
    title = "Píseň " + uuid.uuid4().hex
    with pytest.raises(ls.LyricsSourceDown):
        asyncio.run(ls.fetch_lyrics(track_name=title, artist_name="Někdo", album_name=None, duration_s=200))
    _fake(monkeypatch, [])  # LRCLIB zase běží -> text se najde (nebyl uložen "nenalezeno")
    assert asyncio.run(ls.fetch_lyrics(track_name=title, artist_name="Někdo", album_name=None, duration_s=200))


def test_outage_falls_back_to_other_source(monkeypatch):
    _fake(monkeypatch, [503] * 20)

    async def ovh(*a):
        return {"plain": "záloha", "synced": None, "instrumental": False}

    monkeypatch.setattr(ls, "_lyrics_ovh", ovh)
    result = asyncio.run(ls.fetch_lyrics(track_name="Píseň " + uuid.uuid4().hex, artist_name="Někdo", album_name=None))
    assert result["plain"] == "záloha" and result["partial"]
