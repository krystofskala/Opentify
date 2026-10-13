"""Opakování hned za sebou: líbí se vs. zkoušení s kapelou (13. 10.)."""
from __future__ import annotations

from datetime import datetime, timedelta

from app.home.repeats import analyze


def _t(day, minute):
    return datetime(2026, 9, 1) + timedelta(days=day, minutes=minute)


def test_oblibene_opakovani_v_ruzne_dny():
    rows = [("a", _t(0, 0), None, None), ("a", _t(0, 4), None, None), ("b", _t(0, 9), None, None),
            ("a", _t(5, 0), None, None), ("a", _t(5, 4), None, None)]
    rep = analyze(rows)
    assert len(rep.loved_days["a"]) == 2
    assert "b" not in rep.loved_days


def test_drina_jeden_den_se_nepocita():
    rows = [("x", _t(0, 4 * i), None, None) for i in range(6)]  # 5 opakování za sebou
    assert "x" not in analyze(rows).loved_days


def test_smycka_playlistu_je_zkouseni():
    songs = [f"s{i}" for i in range(10)]
    rows = []
    m = 0
    for loop in range(5):  # 50 poslechů, každá skladba 5x, bez opakování za sebou
        for s in songs:
            rows.append((s, _t(loop, m), "kapela", None))
            m += 5
    rep = analyze(rows)
    assert "playlist:kapela" in rep.practice_sources
    assert set(songs) <= rep.practice_tracks
