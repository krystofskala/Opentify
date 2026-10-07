"""Rozdělení dotazu na dva interprety (hledání spoluprací)."""
from app.catalog.collabs import splits


def test_split_with_separator():
    assert splits("Béla Fleck & Abigail Washburn")[0] == ("Béla Fleck", "Abigail Washburn")
    assert splits("Chris Thile a Michael Daves")[0] == ("Chris Thile", "Michael Daves")


def test_separator_inside_title_also_tries_words():
    assert ("billy strings", "dust in a baggie") in splits("billy strings dust in a baggie")


def test_split_without_separator_prefers_balanced():
    out = splits("marc ocoonr tony rice")
    assert out[0] == ("marc ocoonr", "tony rice")
    assert len(out) == 3


def test_single_word_is_not_split():
    assert splits("Radiohead") == []


def test_track_credits_are_cached_long_without_preview(monkeypatch):
    import asyncio

    import app.catalog.deezer as dzmod

    seen = {}

    async def fake_cached(key, ttl, fetch, is_empty=None):
        seen["key"], seen["ttl"] = key, ttl
        return await fetch()

    client = dzmod.DeezerClient()

    async def fake_get(path, params=None):
        return {"id": 1, "contributors": [{"id": 5}], "preview": "https://signed"}

    monkeypatch.setattr(dzmod, "cached_json", fake_cached)
    monkeypatch.setattr(client, "_get", fake_get)
    out = asyncio.run(client.track_credits("1"))
    assert out == {"id": 1, "contributors": [{"id": 5}]}
    assert seen["key"] == "dz:track_credits:1" and seen["ttl"] >= 30 * 24 * 3600
