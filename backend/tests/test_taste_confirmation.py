"""Vkus ve vrstvách: trvalý vliv jen z návratů z vlastní volby (váhy z auditu
7. 10.), algoritmus třetinou dne, mladý profil podle dnů poslechu, import
podle sbírky / běhů alba a interpreta / reason_start."""

from datetime import datetime, timedelta, timezone

from app.home import activation as av


def _t(day: int, minute: int = 0) -> datetime:
    return datetime(2026, 10, 1, 20, tzinfo=timezone.utc) + timedelta(days=day, minutes=minute)


def test_day_stats_count_algorithm_as_a_third_of_a_day() -> None:
    stats = av.artist_day_stats([(_t(0), "a", False), (_t(0), "a", True), (_t(5), "a", True), (_t(1), "b"), (_t(1), None)])
    days, span = stats["a"]
    assert abs(days - (1 + 1 / 3)) < 1e-9 and round(span) == 5  # den s vlastní volbou = 1, jen algoritmus = 1/3
    assert stats["b"] == (1, 0.0)


def test_persistence_weights_follow_the_audit() -> None:
    assert av.persistence_weight(1, 0) < 0.15  # jednodenní: vydrží 10 %
    assert av.persistence_weight(3, 3) < av.persistence_weight(3, 14)  # rozpětí rozhoduje
    assert av.persistence_weight(5, 5) < 0.3  # týdenní nárazové poslouchání
    assert av.persistence_weight(5, 14) == 1.0
    assert av.persistence_weight(3, 14) >= av.CONFIRMED_AT


def test_one_evening_has_small_influence_on_clean_profile() -> None:
    stats = {"tried": (1, 0.0), "back": (6, 20.0), "liked": (1, 0.0), "algo": (3 * av.ALGO_DAY, 10.0)}
    f = av.tentative_factors(stats, confirmed={"liked"}, listening_days=1)
    assert "back" not in f and "liked" not in f
    assert f["tried"] < 0.2
    assert f["algo"] == f["tried"]  # tři dny jen z Pusť teď = jako jeden den


def test_young_is_measured_in_listening_days() -> None:
    stats = {"tried": (1, 0.0)}
    assert av.tentative_factors(stats, set(), 2)["tried"] < av.tentative_factors(stats, set(), 20)["tried"] < 1
    assert av.tentative_factors(stats, set(), av.YOUNG_DAYS) == {}


def test_import_own_choice_vs_algorithm() -> None:
    rows = [
        (_t(0, 0), "r1", "alb", "art", None),  # album 3x za sebou -> vlastní
        (_t(0, 4), "r2", "alb", "art", None),
        (_t(0, 8), "r3", "alb", "art", None),
        (_t(0, 30), "x1", "o1", "a1", None),  # osamocená cizí skladba -> algoritmus
        (_t(0, 34), "x2", "o2", "a2", "spotify:clickrow"),  # vybral ji -> vlastní
        (_t(0, 38), "x3", "o3", "a3", "spotify:shuffle:trackdone"),  # pokračování -> algoritmus
        (_t(0, 42), "fav", "o4", "a4", None),  # ze sbírky -> vlastní
    ]
    algo = av.import_algorithmic(rows, collection={"fav"})
    assert algo == {3, 5}
