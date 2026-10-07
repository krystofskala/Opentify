"""Pusť teď 8. 10.: rotace jako v rádiu, jistý začátek várky, podíl nového
podle posledního výsledku."""
from datetime import datetime, timedelta

from app.home import activation as av
from app.home import play_now as pn


def _act(plays: dict[str, list[float]]) -> av.Activation:
    """skladba -> stáří poslechů ve dnech."""
    now = datetime(2026, 10, 8, 12, 0)
    act = av.Activation(now=now)
    for rid, ages in plays.items():
        for age in sorted(ages, reverse=True):
            t = now - timedelta(days=age)
            act.timeline.append((t, rid))
            act.last[rid] = t
    act.timeline.sort()
    return act


def test_rotation_by_how_the_song_is_played():
    act = _act({
        "repeat": [0.5, 1.5, 2.5, 3.0],  # 4x za týden -> odstup 1 den, hrála před 12 h
        "fav": [2.0, 30.0],              # oblíbená -> 5 dní, hrála před 2 dny
        "classic": [10.0],               # klasika -> 21 dní, hrála před 10 dny
        "old": [40.0],                   # odstup splněný
    })
    f = pn.rotation_factors(act)
    assert 0.2 < f["repeat"] < 0.3          # (0,5/1)^2
    assert abs(f["fav"] - (2 / 5) ** 2) < 1e-6
    assert abs(f["classic"] - (10 / 21) ** 2) < 1e-6
    assert "old" not in f


def test_rotation_is_gentler_for_small_profile():
    act = _act({"song": [0.1]})
    assert pn.rotation_factors(act)["song"] == pn.ROTATION_FLOOR
    assert pn.rotation_factors(act, small=True)["song"] == 0.2


def test_batch_starts_with_familiar():
    out = ["n1", "f1", "n2", "f2", "f3"]
    assert pn._familiar_first(out, {"n1", "n2"}) == ["f1", "f2", "n1", "n2", "f3"]
    assert pn._familiar_first(["n1", "n2"], {"n1", "n2"}) == ["n1", "n2"]
