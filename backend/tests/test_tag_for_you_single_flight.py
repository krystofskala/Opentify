"""„Pro tebe · X“: souběžná volání sdílí jeden výpočet."""
from __future__ import annotations

import asyncio

import app.tags as tags


def test_concurrent_calls_share_one_build(monkeypatch):
    calls = []

    async def build(tag, user_id):
        calls.append((tag, user_id))
        await asyncio.sleep(0.05)
        return "pl-1"

    monkeypatch.setattr(tags, "_tag_for_you", build)

    async def run():
        a, b = await asyncio.gather(tags.tag_for_you("rock", "u"), tags.tag_for_you("Rock", "u"))
        c = await tags.tag_for_you("rock", "u")  # po dokončení zase nový
        d = await tags.tag_for_you("jazz", "u")
        return a, b, c, d

    assert asyncio.run(run()) == ("pl-1",) * 4
    assert len(calls) == 3
