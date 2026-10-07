"""Mladý profil: trvalý vliv na vkus jen z opakovaných návratů po delší době."""

from datetime import datetime, timedelta, timezone

from app.home import activation as av


def _t(day: int) -> datetime:
    return datetime(2026, 10, 1, 20, tzinfo=timezone.utc) + timedelta(days=day)


def test_day_stats_counts_days_and_span() -> None:
    stats = av.artist_day_stats([(_t(0), "a"), (_t(0), "a"), (_t(5), "a"), (_t(1), "b"), (_t(1), None)])
    assert stats["a"][0] == 2 and round(stats["a"][1]) == 5
    assert stats["b"] == (1, 0.0)


def test_confirmation_needs_repeated_returns_over_time() -> None:
    assert av.confirmation(1, 0) == 0.0
    # Tři dny za sebou: vrací se, ale ještě ne po delší době.
    assert 0 < av.confirmation(3, 2) < 1
    # Dva dny přes týden: delší doba, ale málo návratů.
    assert 0 < av.confirmation(2, 10) < 1
    assert av.confirmation(3, 7) == 1.0


def test_one_evening_has_small_influence_on_clean_profile() -> None:
    stats = {"tried": (1, 0.0), "back": (3, 9.0), "liked": (1, 0.0), "twice": (2, 1.0)}
    f = av.tentative_factors(stats, confirmed={"liked"}, listens=10)
    assert "back" not in f and "liked" not in f
    assert f["tried"] < 0.45
    assert f["tried"] < f["twice"] < 1


def test_effect_fades_with_history() -> None:
    stats = {"tried": (1, 0.0)}
    small = av.tentative_factors(stats, set(), 10)["tried"]
    bigger = av.tentative_factors(stats, set(), 200)["tried"]
    assert small < bigger < 1
    assert av.tentative_factors(stats, set(), av.YOUNG_PROFILE) == {}
