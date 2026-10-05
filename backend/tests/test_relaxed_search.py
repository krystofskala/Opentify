"""Hledání "interpret + skladba" / s nadbytečným slovem: když Deezer na celý
dotaz nevrátí nic, zkusí se rozdělení a kratší dotazy."""
from app.catalog.service import _relaxed_queries


def test_relaxed_queries_split_then_shorten():
    alts = _relaxed_queries("Peter Rowan Old Home Place")
    assert 'artist:"Peter Rowan" track:"Old Home Place"' in alts
    assert alts.index('artist:"Peter Rowan" track:"Old Home Place"') < alts.index("Peter Rowan Old Home")
    assert len(alts) <= 5


def test_short_queries_are_not_relaxed():
    assert _relaxed_queries("Tony Rice") == []
    assert "Tame Impala Currents" in _relaxed_queries("Tame Impala Currents deluxe")
