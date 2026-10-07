"""Rozbor zvuku pro navazování a nálady (plán P4, úroveň A+B).

Z PCM, které už dekóduje měření hlasitosti (app/loudness.py, mono 11 025 Hz),
spočítá numpy:

- **energii** skladby 0..1 -- šumovost spektra, podíl výšek a jas (zkreslené
  kytary, činely, syntezátory proti akustice a klavíru). Záměrně NE hlasitost: stará "energie"
  okrajů byla z 91 % hlasitost masteringu (audit 7. 10.), takže řadila
  podle éry nahrávky místo nálady;
- **tempo** (BPM, s jistotou) z autokorelace obálky nástupů;
- **energii začátku a konce** z prvních / posledních 10 s skutečné hudby
  (bez ticha a doznění) -- na tom stojí plynulé navazování;
- ticho na začátku a konci.

Vše uloží do `TrackFeatures` (verze výpočtu -> přepočet při změně).
"""

from __future__ import annotations

import logging

import numpy as np

logger = logging.getLogger(__name__)

VERSION = 1
SR = 11025
FRAME = 1024
HOP = 512
EDGE_S = 10.0
SILENCE_DB = -50.0  # pod tímhle (vůči špičce skladby) je ticho / doznění


def _frames(x: np.ndarray) -> np.ndarray:
    n = 1 + max(0, (len(x) - FRAME) // HOP)
    idx = np.arange(FRAME)[None, :] + HOP * np.arange(n)[:, None]
    return x[idx]


def _norm(v: float, lo: float, hi: float) -> float:
    return float(min(1.0, max(0.0, (v - lo) / (hi - lo))))


# Meze (p10/p90) z kalibrace na knihovně 7. 10. -- klidní (Ben Howard,
# Lumineers, Bon Iver…) proti energickým (Foo Fighters, twenty one pilots,
# Vypsaná fiXa…): šumovost AUC 0,99, podíl výšek 0,98, jas 0,97; hlasitost
# masteringu jen 0,69 a nástupy/pulz nerozlišovaly vůbec.
_FLAT = (-2.92, -1.11)  # log10 spektrální plochosti
_HIGH = (-2.57, -0.98)  # log10 podílu výkonu nad 2 kHz
_CENTROID = (240.0, 735.0)  # Hz


def _energy(flatness: float, high_ratio: float, centroid: float) -> float:
    """0..1 -- jas a "drsnost" zvuku (zkreslení, činely, syntezátory),
    nezávisle na hlasitosti masteringu."""
    parts = (
        _norm(float(np.log10(flatness + 1e-12)), *_FLAT),
        _norm(float(np.log10(high_ratio + 1e-12)), *_HIGH),
        _norm(centroid, *_CENTROID),
    )
    return round(sum(parts) / 3, 4)


def _segment(power: np.ndarray, rms: np.ndarray, freqs: np.ndarray) -> tuple[float, float, float]:
    """(plochost, podíl výšek, těžiště Hz) -- mediány přes slyšitelné rámce."""
    if len(power) == 0:
        return 0.0, 0.0, 0.0
    loud = rms > rms.max() * 10 ** (-30 / 20)
    if not loud.any():
        return 0.0, 0.0, 0.0
    p = power[loud]
    total = p.sum(axis=1) + 1e-12
    flat = np.exp(np.log(p + 1e-12).mean(axis=1)) / (p.mean(axis=1) + 1e-12)
    high = p[:, freqs > 2000].sum(axis=1) / total
    centroid = (p * freqs[None, :]).sum(axis=1) / total
    return float(np.median(flat)), float(np.median(high)), float(np.median(centroid))


def _tempo(onset_env: np.ndarray) -> tuple[float | None, float]:
    """BPM 60-180 z autokorelace spektrálního toku; (bpm, jistota 0..1).
    Jistota bývá nízká u volné hudby -- navazování ji bere v úvahu."""
    if len(onset_env) < 200:
        return None, 0.0
    env = onset_env - onset_env.mean()
    ac = np.correlate(env, env, mode="full")[len(env) - 1 :]
    if ac[0] <= 0:
        return None, 0.0
    ac = ac / ac[0]
    fps = SR / HOP
    lo, hi = int(fps * 60 / 180), int(fps * 60 / 60)
    if hi >= len(ac):
        return None, 0.0
    lag = lo + int(np.argmax(ac[lo:hi]))
    conf = float(max(0.0, ac[lag]))
    if lo < lag < hi - 1:
        a, b, c = ac[lag - 1], ac[lag], ac[lag + 1]
        den = a - 2 * b + c
        shift = 0.5 * (a - c) / den if den != 0 else 0.0
    else:
        shift = 0.0
    return round(float(60.0 * fps / (lag + shift)), 1), round(conf, 3)


def compute(pcm: bytes) -> dict | None:
    """PCM s16le mono 11 025 Hz -> rysy skladby, nebo None (moc krátké)."""
    x = np.frombuffer(pcm, dtype=np.int16).astype(np.float32) / 32768.0
    if len(x) < SR * 5:
        return None
    frames = _frames(x)
    rms = np.sqrt((frames**2).mean(axis=1)) + 1e-9
    window = np.hanning(FRAME).astype(np.float32)
    mag = np.abs(np.fft.rfft(frames * window, axis=1)).astype(np.float32)
    freqs = np.fft.rfftfreq(FRAME, 1.0 / SR).astype(np.float32)

    if float(rms.max()) < 1e-4:  # pod -80 dBFS: celé ticho
        return None
    # Skutečná hudba: od prvního do posledního rámce nad prahem ticha.
    audible = np.where(20 * np.log10(rms / rms.max()) > SILENCE_DB)[0]
    if len(audible) == 0:
        return None
    first, last = int(audible[0]), int(audible[-1])
    fps = SR / HOP
    edge = int(EDGE_S * fps)

    power = mag.astype(np.float64) ** 2
    logmag = np.log1p(mag * 100.0)
    onset_env = np.concatenate([[0.0], np.maximum(0.0, np.diff(logmag, axis=0)).sum(axis=1)])
    bpm, conf = _tempo(onset_env[first : last + 1])
    whole = _segment(power[first : last + 1], rms[first : last + 1], freqs)
    head_sl = slice(first, first + edge)
    tail_sl = slice(max(first, last + 1 - edge), last + 1)
    head = _segment(power[head_sl], rms[head_sl], freqs)
    tail = _segment(power[tail_sl], rms[tail_sl], freqs)
    peak_db = 20 * np.log10(rms.max())

    def level_db(sl: slice) -> float:
        seg = rms[sl]
        return round(float(20 * np.log10(np.sqrt((seg**2).mean())) - peak_db), 2) if len(seg) else 0.0

    return {
        "version": VERSION,
        "energy": _energy(*whole),
        "intro_energy": _energy(*head),
        "outro_energy": _energy(*tail),
        # Hlasitost okrajů vůči špičce skladby (dB): tichý nástup / dozvuk.
        "intro_level_db": level_db(slice(first, first + edge)),
        "outro_level_db": level_db(slice(max(first, last + 1 - edge), last + 1)),
        "bpm": bpm,
        "bpm_confidence": conf,
        "flatness": round(whole[0], 5),
        "high_ratio": round(whole[1], 5),
        "centroid_hz": round(whole[2], 1),
        "head_silence_s": round(first * HOP / SR, 2),
        "tail_silence_s": round((len(rms) - 1 - last) * HOP / SR, 2),
    }
