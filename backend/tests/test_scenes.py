"""Mapa scén a chycené skladby (F3, 13. 10.)."""
from __future__ import annotations

import random
from collections import Counter
from datetime import datetime, timedelta

from app.home import scenes
from app.home.caught import caught_tracks


def test_louvain_rozdeli_dve_oddelene_skupiny():
    adj: dict[str, dict[str, float]] = {}

    def link(a, b, w=1.0):
        adj.setdefault(a, {})[b] = w
        adj.setdefault(b, {})[a] = w

    for group in (["a1", "a2", "a3", "a4"], ["b1", "b2", "b3", "b4"]):
        for i, x in enumerate(group):
            for y in group[i + 1:]:
                link(x, y)
    link("a1", "b1", 0.05)  # slabý most
    node_of = scenes._louvain(adj, 1.0)
    assert len({node_of[x] for x in ("a1", "a2", "a3", "a4")}) == 1
    assert node_of["a1"] != node_of["b1"]


def test_male_skupiny_se_pripoji_k_nejblizsi():
    groups = {"x": {"a1", "a2", "a3", "a4", "a5"}, "y": {"b1"}}
    adj = {"b1": {"a1": 1.0}, "a1": {"b1": 1.0}}
    merged = scenes._merge_small(groups, adj)
    assert merged == {"x": {"a1", "a2", "a3", "a4", "a5", "b1"}}


def test_feat_varianty_k_hlavnimu_interpretovi():
    names = {"p": "Passenger", "pf": "Passenger feat. Josh Pyke", "ajs": "Angus & Julia Stone"}
    assert scenes._feat_merges(names) == {"pf": "p"}


def _scene(sid, weight, now, n=6):
    return scenes.Scene(id=sid, artists=[f"{sid}{i}" for i in range(n)], weight=weight, now=now)


def test_spici_sceny_a_pauza_po_ukazani():
    smap = scenes.SceneMap([_scene("live", 0.3, 0.6), _scene("old", 0.2, 0.01), _scene("old2", 0.2, 0.02)])
    picks = Counter()
    for seed in range(200):
        for sc in scenes.pick_dormant(smap, 1, random.Random(seed), today="2026-10-13", shown={"old": "2026-10-12"}):
            picks[sc.id] += 1
    assert "live" not in picks  # hraje teď -- není spící
    assert picks["old2"] > picks["old"] * 5  # "old" byla včera, má pauzu


class _Act:
    def __init__(self, now, timeline, first, algo=None):
        self.now, self.timeline, self.first = now, timeline, first
        self.timeline_algo = algo or [False] * len(timeline)


def test_chycena_nova_i_navrat_po_pauze(monkeypatch):
    import app.home.caught as caught

    monkeypatch.setattr(caught, "_recent_likes", lambda user_id, since: [])
    now = datetime(2026, 10, 13, 12)
    tl = [
        (now - timedelta(days=5), "nova"), (now - timedelta(days=2), "nova"),  # nová, 2 dny
        (now - timedelta(days=400), "stara"), (now - timedelta(days=3), "stara"), (now - timedelta(days=1), "stara"),
        (now - timedelta(days=30), "bezna"), (now - timedelta(days=4), "bezna"), (now - timedelta(days=2), "bezna"),
        (now - timedelta(days=1), "jednou"),
    ]
    tl.sort()
    first = {"nova": now - timedelta(days=5), "stara": now - timedelta(days=400), "bezna": now - timedelta(days=200),
             "jednou": now - timedelta(days=1)}
    out = caught_tracks("u", _Act(now, tl, first))
    assert set(out) == {"nova", "stara"}  # běžně hraná ani jednou puštěná ne
