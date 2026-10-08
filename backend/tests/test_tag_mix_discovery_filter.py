"""Objevy v mixu stylu jen od interpretů, kteří styl opravdu hrají (8. 10.:
My Chemical Romance v „Singer-songwriter“, Emma Ruth Rundle v Electronic)."""

import asyncio

from app.home import taste_bridge

TAGS = {
    "My Chemical Romance": [("rock", 100), ("alternative", 90), ("punk rock", 54), ("emo", 52)],
    "Glen Hansard": [("singer-songwriter", 100), ("folk", 89), ("acoustic", 58)],
    "Tom Petty": [("classic rock", 100), ("rock", 87), ("singer-songwriter", 43)],
    "Neznámý": [],
}


def test_items_playing_keeps_only_artists_with_strong_style_tag(monkeypatch):
    async def fake_tags(name, _sem):
        return TAGS.get(name, [])

    monkeypatch.setattr(taste_bridge, "_tags_of", fake_tags)
    items = [{"artist": n, "title": f"{n} song"} for n in TAGS]
    kept = asyncio.run(taste_bridge.items_playing(items, ["singer-songwriter"]))
    assert [x["artist"] for x in kept] == ["Glen Hansard", "Tom Petty", "Neznámý"]
