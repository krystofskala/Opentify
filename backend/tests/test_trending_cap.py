"""Trendy na ListenBrainz: nejvýš 2 skladby od interpreta (14. 10., BTS 23 z 38)."""
from types import SimpleNamespace

from app.home.generators import _cap_trending


def test_strop_na_interpreta_a_poradi():
    recs = [SimpleNamespace(id=f"b{i}", artist_name="BTS") for i in range(5)]
    recs += [SimpleNamespace(id="j1", artist_name="Jung Kook feat. Jack Harlow"), SimpleNamespace(id="j2", artist_name="Jung Kook"),
             SimpleNamespace(id="j3", artist_name="Jung Kook"), SimpleNamespace(id="x", artist_name="Taylor Swift")]
    out = [r.id for r in _cap_trending(recs)]
    assert out == ["b0", "b1", "j1", "j2", "x"]
