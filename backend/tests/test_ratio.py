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
