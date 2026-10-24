"""Stálice a nové skladby drží styl jádra mixu; nové rovnoměrně po mixu (24. 10.)."""

from app.home.energy_flow import core_artists, near_artists
from app.home.personal_mixes import _interleave

FOLK = {"folk": 1.0, "singer-songwriter": 0.8, "acoustic": 0.5}
ROCK = {"rock": 1.0, "pop rock": 0.7, "alternative": 0.5}
STYLES = {"plihal": FOLK, "flynn": {"folk": 1.0, "indie": 0.6}, "mnaga": ROCK, "stones": {"classic rock": 1.0, "rock": 0.8}}


def test_core_keeps_featured_close_to_first() -> None:
    assert core_artists(["plihal", "mnaga", "flynn"], STYLES) == ["plihal", "flynn"]
    assert core_artists(["mnaga", "plihal", "flynn"], STYLES) == ["plihal", "flynn"]
    assert core_artists(["nikdo"], STYLES) == ["nikdo"]


def test_near_drops_off_style_untagged_pass() -> None:
    assert near_artists({"plihal", "flynn", "mnaga", "stones", "beztagu"}, ["plihal", "flynn"], STYLES) == {
        "plihal", "flynn", "beztagu",
    }


def test_interleave_spreads_new_over_whole_mix() -> None:
    familiar = [f"k{i}" for i in range(30)]
    new = [f"n{i}" for i in range(10)]
    out = _interleave(familiar, new)
    assert sorted(out) == sorted(familiar + new)
    assert out[0] == "k0"
    positions = [i for i, r in enumerate(out) if r.startswith("n")]
    assert positions[-1] >= len(out) - 4  # žádný blok samých známých na konci
    assert all(b - a >= 3 for a, b in zip(positions, positions[1:]))
    assert _interleave(["k"], []) == ["k"] and _interleave([], ["n"]) == ["n"]
