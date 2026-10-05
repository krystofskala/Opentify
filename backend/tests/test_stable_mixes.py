"""Stálá čísla Denních mixů a "jedna skladba = jeden mix" (plán P1)."""
from app.home import personal_mixes as pm


def _c(*artists):
    return pm.Cluster(artists=list(artists), signature=set(), radio_seeds=[])


def test_groups_keep_yesterdays_numbers():
    previous = {1: ["pilots", "coldplay", "yungblud"], 2: ["angus", "dope", "jose"], 3: ["fixa", "mnaga"]}
    today = [_c("angus", "dope", "nick"), _c("fixa", "mnaga", "plihal"), _c("newband", "other"), _c("pilots", "coldplay")]
    numbers = {tuple(c.artists): n for n, c in pm._stable_numbers(today, previous)}
    assert numbers[("pilots", "coldplay")] == 1
    assert numbers[("angus", "dope", "nick")] == 2
    assert numbers[("fixa", "mnaga", "plihal")] == 3
    assert numbers[("newband", "other")] == 4  # nová skupina -> volné číslo


def test_prefer_unused_keeps_used_as_fallback():
    assert pm.prefer_unused(["a", "b", "c", "d"], {"b", "c"}) == ["a", "d", "b", "c"]
