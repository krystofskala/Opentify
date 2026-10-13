"""Objevování a čerstvé mixy (audit 13. 10.)."""
from __future__ import annotations

import random
from collections import Counter

from app.home import personal_mixes as pm
from app.recommendations.anti_ai_filter import AntiAIFilter


def test_anti_ai_jen_cela_slova():
    f = AntiAIFilter()
    for ok in ("Audioslave", "Studio Killers", "Song (Studio Version)", "Track (Official Audio)", "Kaimi"):
        assert not f.is_blocked_text(ok), ok
    for bad in ("Suno AI", "made with Suno", "Udio", "AI generated beat"):
        assert f.is_blocked_text(bad), bad


def test_pamet_mixu_tlumi_vcerejsi_a_nove_nevraci(monkeypatch):
    taste = pm.Taste()
    taste.listen_counts = Counter({"k1": 5, "k2": 3})
    taste.artist_of = {"k1": "a1", "k2": "a2", "n1": "a3"}
    history = [
        (1, {"1": ["k1", "n1"]}),  # včera: známá k1 a nová n1
        (10, {"1": ["k2"]}),  # mimo 7 dní -- jen pro "dvakrát nabídnutá"
    ]
    from app.home import mix_log

    monkeypatch.setattr(mix_log, "recent", lambda user_id, day: history)
    mem = pm._mix_memory("u", "2026-10-13", taste)
    assert mem.track_factor("k1") == pm.MIX_PER_SERVE  # včera = plná penalizace
    assert mem.track_factor("k2") == 1.0  # před 10 dny už ne
    assert mem.artist_factor("a1") < 1.0
    assert "n1" in mem.offered_new  # nabídnutá nová se týden nevrací
    assert "k1" not in mem.offered_new


def test_hlavni_interpreti_se_stridaji():
    taste = pm.Taste()
    artists = [f"a{i}" for i in range(12)]
    taste.artist_weight = Counter({a: 10 - i * 0.5 for i, a in enumerate(artists)})
    cluster = pm.Cluster(artists=artists)
    mem = pm.MixMemory()
    days = {tuple(pm._featured_artists(cluster, taste, mem, random.Random(f"u:{d}:1"))) for d in range(10)}
    assert len(days) > 3  # ne každý den tíž tři
    # Kdo byl hlavní nedávno, má menší šanci.
    mem.artist_exp["a0"] = 5.0
    picks = Counter(a for d in range(200) for a in pm._featured_artists(cluster, taste, mem, random.Random(d)))
    assert picks["a0"] < picks["a1"]


def test_zname_pro_objevy_jen_navraty_a_ulozene():
    class Act:
        def artist_days(self):
            return {"a_navrat": (3.0, 40.0), "a_jednou": (1.0, 0.0)}

    taste = pm.Taste()
    taste.activation = Act()
    taste.artist_name = {"a_navrat": "Návrat", "a_jednou": "Jednou", "a_srdce": "Srdce"}
    taste.artist_of = {"r1": "a_srdce"}
    taste.liked = ["r1"]
    names, _dz = pm._known_for_discover(taste)
    assert "návrat" in names and "srdce" in names
    assert "jednou" not in names  # jeden náhodný poslech z interpreta známého nedělá
