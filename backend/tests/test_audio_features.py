"""Rozbor zvuku: energie podle zvuku (ne hlasitosti), tempo, okraje."""
from __future__ import annotations

import numpy as np

from app import audio_features as af


def _pcm(x: np.ndarray) -> bytes:
    return (np.clip(x, -1, 1) * 32767).astype(np.int16).tobytes()


def _t(seconds: float) -> np.ndarray:
    return np.arange(int(af.SR * seconds)) / af.SR


def test_noisy_bright_sound_is_more_energetic_than_soft_tone_even_when_quieter():
    rng = np.random.default_rng(1)
    t = _t(30)
    soft_tone = 0.8 * np.sin(2 * np.pi * 220 * t)  # hlasitý, ale čistý tón
    noisy = 0.2 * rng.standard_normal(len(t))  # tišší, ale šum jako činely/zkreslení
    calm = af.compute(_pcm(soft_tone))
    loud = af.compute(_pcm(noisy))
    assert calm and loud
    assert loud["energy"] > calm["energy"] + 0.4


def test_tempo_of_click_track():
    t = _t(30)
    x = np.zeros_like(t)
    beat = int(af.SR * 60 / 120)  # 120 BPM
    rng = np.random.default_rng(2)
    for start in range(0, len(x) - 400, beat):
        x[start : start + 400] += rng.standard_normal(400) * np.exp(-np.arange(400) / 80)
    f = af.compute(_pcm(0.5 * x))
    assert f and f["bpm"] is not None
    assert min(abs(f["bpm"] - 120), abs(f["bpm"] - 60), abs(f["bpm"] - 240)) < 4


def test_silence_and_edges():
    t = _t(40)
    x = 0.5 * np.sin(2 * np.pi * 330 * t)
    x[: af.SR * 3] = 0  # 3 s ticha na začátku
    x[-af.SR * 10 :] *= np.linspace(1, 0.01, af.SR * 10)  # dlouhý dozvuk
    f = af.compute(_pcm(x))
    assert f and 2.5 < f["head_silence_s"] < 3.5
    assert f["outro_level_db"] < f["intro_level_db"]
    assert af.compute(_pcm(np.zeros(af.SR * 10))) is None
    assert af.compute(_pcm(np.zeros(af.SR * 2))) is None


def test_tempo_gap_half_double_is_same():
    from app.home.energy_flow import _tempo_gap

    assert _tempo_gap(120, 60) == 0
    assert _tempo_gap(120, 121) < 0.1
    assert _tempo_gap(120, 160) == 1.0
