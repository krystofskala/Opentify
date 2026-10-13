"""Kolik nového: samoladění a průběh várky (7t, 13. 10.)."""
from __future__ import annotations

from app.home.play_now import _no_new_in_a_row
from app.home.ratio import MAX_OFFSET, next_offset


def test_samoladeni_pridava_ubira_a_drzi_meze():
    assert next_offset(0.0, 60, 0.30, 100, 0.25) == 0.05  # nové jako známé -> víc
    assert next_offset(0.0, 60, 0.70, 100, 0.25) == -0.05  # nové hodně přeskakuje -> míň
    assert next_offset(0.0, 60, 0.45, 100, 0.25) == 0.0
    assert next_offset(0.0, 10, 0.0, 100, 0.25) == 0.0  # málo dat
    assert next_offset(MAX_OFFSET, 60, 0.2, 100, 0.25) == MAX_OFFSET


def test_malo_nikdy_dve_nove_za_sebou():
    out = ["f1", "f2", "n1", "n2", "f3", "f4", "n3", "f5"]
    res = _no_new_in_a_row(out, {"n1", "n2", "n3"})
    assert sorted(res) == sorted(out)
    assert not any(a[0] == b[0] == "n" for a, b in zip(res, res[1:]))
    assert res[:3] == ["f1", "f2", "n1"]


def test_objevy_v_blocich_podle_sceny(monkeypatch):
    import random

    from app.home import personal_mixes as pm
    from app.home import scenes

    smap = scenes.SceneMap([
        scenes.Scene(id="pp", artists=["blink"], label="pop punk, punk"),
        scenes.Scene(id="jz", artists=["norah"], label="jazz, vocal jazz"),
        scenes.Scene(id="emo", artists=["tbs"], label="emo, pop punk"),
    ])
    monkeypatch.setattr(scenes, "load", lambda _u: smap)
    seed = {"p1": "blink", "p2": "blink", "j1": "norah", "j2": "norah", "e1": "tbs", "e2": "tbs"}
    out = pm._in_scene_blocks("u", ["p1", "j1", "e1", "p2", "j2", "e2"], seed, random.Random(1))
    kinds = [t[0] for t in out]
    assert sum(1 for a, b in zip(kinds, kinds[1:]) if a != b) == 2  # jen 2 přechody
    assert abs(kinds.index("p") - kinds.index("e")) <= 2 or kinds[0] == "j"  # pop-punk vedle emo
