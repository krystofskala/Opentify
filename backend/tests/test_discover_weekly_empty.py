"""Objevy týdne u profilu bez poslechů: tiše 0, ne chyba v logu."""
import asyncio
from collections import Counter
from types import SimpleNamespace

from app.home import personal_mixes as pm


def test_empty_taste_returns_zero_without_error(monkeypatch):
    monkeypatch.setattr(pm, "_already_built", lambda *_a: None)
    monkeypatch.setattr(pm, "load_taste", lambda _uid: SimpleNamespace(artist_weight=Counter()))
    assert asyncio.run(pm.build_discover_weekly()) == 0
