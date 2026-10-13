"""Vlny poslechu a Kam dál (7v, 13. 10.)."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

from app.home import scenes, waves


class _Act:
    def __init__(self, timeline, artist_of):
        self.timeline = timeline
        self.timeline_algo = [False] * len(timeline)
        self.artist_of = artist_of


def _history():
    """400 dní: hlavně scéna A, 40 dní vlna scény B, pak zase A."""
    start = datetime(2025, 1, 1, tzinfo=timezone.utc)
    tl, artist_of = [], {}
    for d in range(400):
        day = start + timedelta(days=d)
        for i in range(10):
            wave = 300 <= d < 340 and i < 6
            a = f"b{i % 3}" if wave else f"a{i % 4}"
            rid = f"{a}-{d}-{i}"
            artist_of[rid] = a
            tl.append((day + timedelta(minutes=i * 5), rid))
    smap = scenes.SceneMap([
        scenes.Scene(id="A", artists=["a0", "a1", "a2", "a3"]),
        scenes.Scene(id="B", artists=["b0", "b1", "b2"]),
    ])
    return _Act(tl, artist_of), smap, start


def test_vlna_nalezena_a_opada():
    act, smap, start = _history()
    rep = waves.detect(act, smap, today=(start + timedelta(days=360)).date())
    b = [w for w in rep.waves if w.scene == "B"]
    assert len(b) == 1
    assert (start + timedelta(days=295)).date() <= b[0].peak <= (start + timedelta(days=340)).date()
    assert rep.current() is not None and rep.current().scene == "B"


def test_bez_vlny_nic():
    act, smap, start = _history()
    rep = waves.detect(act, smap, today=(start + timedelta(days=200)).date())
    assert not [w for w in rep.waves if w.scene == "B"]


def test_davka_kam_dal_podle_typu(monkeypatch):
    from app.home import kam_dal

    data = {"listener": "steady", "paths": {"navrat": {"scene": "X", "ids": ["r"]}}, "wave": {"title": "pop punk"}}
    monkeypatch.setattr(kam_dal, "load", lambda _u: data)
    days = [f"2026-10-{d:02d}" for d in range(1, 31)] + [f"2026-11-{d:02d}" for d in range(1, 31)]
    steady = sum(1 for d in days if kam_dal.path_scene("u", d))
    data["listener"] = "wave"
    wave = sum(1 for d in days if kam_dal.path_scene("u", d))
    assert wave == len(days)
    assert 0 < steady < len(days) // 2  # stálý posluchač vzácně, ale ne nikdy
