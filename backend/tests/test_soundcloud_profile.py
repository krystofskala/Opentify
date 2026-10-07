"""SoundCloud profil interpreta: Go+ ukázky (policy SNIP) se vynechají,
délka se doplní z podrobností; bez podrobností jako dřív."""
from __future__ import annotations

import asyncio

import app.soundcloud as sc


def _flat(_url):
    return {"entries": [
        {"id": 1, "title": "Nishi Jazz", "url": "https://soundcloud.com/prince/nishi-jazz"},
        {"id": 2, "title": "17 Days", "url": "https://soundcloud.com/prince/17-days-1"},
    ]}


async def _no_cache(key, ttl, fetch, is_empty=None):
    return await fetch()


def test_go_plus_snippets_are_dropped(monkeypatch):
    monkeypatch.setattr(sc, "cached_json", _no_cache)
    monkeypatch.setattr(sc, "_extract", _flat)
    monkeypatch.setattr(sc, "_track_details", lambda ids: {
        "1": {"id": 1, "policy": "SNIP", "duration": 30000},
        "2": {"id": 2, "policy": "ALLOW", "duration": 382710},
    })
    items = asyncio.run(sc.profile_tracks("https://soundcloud.com/prince"))
    assert [i["title"] for i in items] == ["17 Days"]
    assert items[0]["duration"] == 382.71


def test_without_details_nothing_is_filtered(monkeypatch):
    monkeypatch.setattr(sc, "cached_json", _no_cache)
    monkeypatch.setattr(sc, "_extract", _flat)

    def boom(ids):
        raise RuntimeError("api")

    monkeypatch.setattr(sc, "_track_details", boom)
    items = asyncio.run(sc.profile_tracks("https://soundcloud.com/prince"))
    assert [i["title"] for i in items] == ["Nishi Jazz", "17 Days"]
