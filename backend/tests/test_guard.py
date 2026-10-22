"""Společný filtr skládání (app/home/guard.py, OP-ALG1) a odcházející
interpreti (activation.fading)."""
from datetime import datetime, timezone

from app.home import activation as av
from app.home.guard import Guard, is_junk


def _guard() -> Guard:
    return Guard(
        banned_artists={"bad-artist"},
        bad_tracks={"bad-track"},
        skipped={"skipped"},
        paused={"paused"},
        tired={"tired"},
        skip_heavy={"heavy"},
        feedback={"less": -5.0, "more": 5.0},
    )


def test_hard_rules_apply_to_familiar_and_new():
    gd = _guard()
    for new in (False, True):
        assert not gd.allowed("bad-track", "a", new=new)
        assert not gd.allowed("skipped", "a", new=new)
        assert not gd.allowed("x", "bad-artist", new=new)
        assert gd.allowed("x", "a", new=new)


def test_new_only_rules():
    gd = _guard()
    assert gd.allowed("paused", "a") and not gd.allowed("paused", "a", new=True)
    assert gd.allowed("x", "less") and not gd.allowed("x", "less", new=True)


def test_familiar_soft_weights():
    gd = _guard()
    assert gd.weight("x", "a") == 1.0
    assert gd.weight("heavy", "a") == 0.3
    assert gd.weight("tired", "a") == 0.3
    assert gd.weight("x", "less") == 0.5
    assert gd.weight("x", "more") == 1.5


def test_filter_without_weights_treats_unknown_as_new():
    gd = _guard()
    artist_of = {"k": "a", "paused": "a", "m": "less", "n": "a"}
    assert gd.filter(["k", "paused", "m", "n"], artist_of, known={"k", "paused"}) == ["k", "paused", "n"]
    assert gd.filter(["k", "paused", "n"], artist_of, known={"k"}) == ["k", "n"]


def test_merge_keeps_what_either_listener_refuses():
    a = Guard(bad_tracks={"t1"}, feedback={"x": -5.0})
    b = Guard(banned_artists={"y"}, feedback={"x": 5.0})
    m = a.merge(b)
    assert not m.allowed("t1", "z") and not m.allowed("t2", "y")
    assert m.feedback["x"] == -5.0


def test_junk_versions():
    assert is_junk("Song (Karaoke Version)")
    assert is_junk("Song - slowed + reverb")
    assert is_junk("Song", "Made Famous By X")
    assert not is_junk("Song (Live)")


def test_fading_artist_weakens_steady_does_not():
    act = av.Activation(now=datetime(2026, 10, 22, tzinfo=timezone.utc))
    act.artist_of = {"old": "gone", "keep": "steady", "rise": "new"}
    # Odešel: ve střední vrstvě hodně, v krátké skoro nic.
    act.medium.update({"old": 6.0, "keep": 3.0, "rise": 1.0})
    act.short.update({"old": 0.2, "keep": 1.5, "rise": 1.0})
    fade = act.fading()
    assert "steady" not in fade and "new" not in fade
    assert fade["gone"] == av.FADE_FLOOR
