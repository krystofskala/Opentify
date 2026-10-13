"""Rozbor ukázek na pozadí: přísné párování skladby bez deezer id (13. 10.)."""
from __future__ import annotations

import asyncio

from app import preview_features as pf


class _Dz:
    async def search(self, query, limit):
        return {"data": [
            {"title": "On My Hands (Live)", "artist": {"name": "Hugh Coltman"}, "duration": 400, "preview": "live"},
            {"title": "On My Hands", "artist": {"name": "Somebody Else"}, "duration": 317, "preview": "jiny"},
            {"title": "On My Hands", "artist": {"name": "Hugh Coltman"}, "duration": 318, "preview": "ok"},
        ]}


def test_ukazka_jen_stejna_skladba(monkeypatch):
    import app.catalog.deezer as dz

    monkeypatch.setattr(dz, "get_deezer_client", lambda: _Dz())
    # Živá verze má jinou délku, jiný interpret nesedí -> studiová.
    assert asyncio.run(pf._search_preview("Hugh Coltman", "On My Hands", 317_000)) == "ok"
    assert asyncio.run(pf._search_preview("Hugh Coltman", "Jiná píseň", None)) is None
