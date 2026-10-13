"""Vlny poslechu (7v, 13. 10.: "poslech chodí ve vlnách podle žánrů; když
vlna opadla, Spotify neměl připravené další rabbit holes").

Vlna = scéna (app/home/scenes.py), která na pár týdnů výrazně převáží:
v klouzavém 14denním okně má aspoň `MIN_SHARE` poslechů, `LIFT`× víc než
svou normální hladinu za předchozí rok (bez posledních 28 dní), aspoň
`MIN_PLAYS` vlastních poslechů a poslech aspoň ve `MIN_DAYS` dnech.
Poslech puštěný algoritmem se počítá třetinou. Mezery do `GAP` dní se
slévají, vlna má aspoň `MIN_LEN` dní. Ověřeno na historii vlastníka
(agent 13. 10.): 74 vln, srdíčka přicházejí ve vlně své scény 17× častěji
než náhodou.

Živý stav vlny: roste -> vrchol -> opadá (>= 10 dní po vrcholu a podíl
<= 0,6 × vrchol, nebo už není "ve vlně") -> skončila (< 0,3 × vrchol nebo
45 dní po konci).

Typ posluchače (mění jen dávku vzdálenějších nabídek, nikdy je nevypíná --
pravidlo 13. 10. "nezazdít dveře k rozšíření"):
- wave: >= 45 % dní ve vlnách, >= 4 vlny, >= 6 scén v typickém měsíci
  (scéna s aspoň 3 % poslechů měsíce);
- steady: <= 4 scény v typickém měsíci nebo jedna scéna >= 40 % poslechů;
- mixed: ostatní; unknown: málo dat (< 180 dní poslechu / 12 měsíců).
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field
from datetime import date, timedelta

import numpy as np

WINDOW = 14
MIN_SHARE = 0.12
LIFT = 4.0
MIN_PLAYS = 10
MIN_DAYS = 4
GAP = 28
MIN_LEN = 14
LIVE_MIN_LEN = 7
BASE_DAYS = 365
BASE_SKIP = 28
ALGO_WEIGHT = 1 / 3
FADING_AFTER_PEAK = 10
FADING_RATIO = 0.6
ENDED_RATIO = 0.3
ENDED_AFTER_DAYS = 45
SIBLING_SIM = 0.5
HISTORY_DAYS = 2 * 365


@dataclass
class Wave:
    scenes: list[str]  # rodina scén (sourozenecké souběžné vlny)
    onset: date
    peak: date
    end: date
    fade: date | None
    peak_share: float
    share_now: float = 0.0
    state: str = "ended"  # rising | peak | fading | ended
    artists: list[str] = field(default_factory=list)  # nejhranější interpreti vlny

    @property
    def scene(self) -> str:
        return self.scenes[0]

    def to_json(self) -> dict:
        return {
            "scenes": self.scenes, "onset": self.onset.isoformat(), "peak": self.peak.isoformat(),
            "end": self.end.isoformat(), "fade": self.fade.isoformat() if self.fade else None,
            "peakShare": round(self.peak_share, 3), "shareNow": round(self.share_now, 3),
            "state": self.state, "artists": self.artists,
        }


@dataclass
class WaveReport:
    waves: list[Wave]
    listener: str  # wave | steady | mixed | unknown
    wave_day_share: float
    scenes_per_month: float
    top_scene_share: float

    def current(self) -> Wave | None:
        """Nejčerstvější vlna, která opadá nebo nedávno skončila (pro Kam dál)."""
        live = [w for w in self.waves if w.state in ("fading", "ended")]
        return live[-1] if live else None


def _roll(v: np.ndarray, w: int) -> np.ndarray:
    c = np.cumsum(np.concatenate([np.zeros(v.shape[:-1] + (1,)), v], axis=-1), axis=-1)
    out = c[..., w:] - c[..., :-w]
    return np.concatenate([np.zeros(v.shape[:-1] + (w - 1,)), out], axis=-1)


def detect(act, smap, today: date | None = None, min_len: int = MIN_LEN, sims=None) -> WaveReport:
    """Vlny z `act.timeline` do dne `today` (offline přehrání historie i živě).
    `sims(a, b)` = podobnost scén podle štítků (sourozenecké vlny se slijí)."""
    scene_of = smap.scene_of()
    ids = [s.id for s in smap.scenes]
    idx = {s: i for i, s in enumerate(ids)}
    algo = act.timeline_algo or [False] * len(act.timeline)
    rows = [(t.date(), rid, al) for (t, rid), al in zip(act.timeline, algo)]
    if today is not None:
        rows = [r for r in rows if r[0] <= today]
    if not rows or not ids:
        return WaveReport([], "unknown", 0.0, 0.0, 0.0)
    d0, d1 = rows[0][0], today or rows[-1][0]
    nd = (d1 - d0).days + 1
    X = np.zeros((len(ids), nd))
    D = np.zeros((len(ids), nd))
    T = np.zeros(nd)
    per_artist: dict[str, Counter] = {s: Counter() for s in ids}
    listening_days = set()
    for d, rid, al in rows:
        i = (d - d0).days
        w = ALGO_WEIGHT if al else 1.0
        T[i] += w
        listening_days.add(i)
        a = act.artist_of.get(rid)
        s = scene_of.get(a)
        if s is not None:
            X[idx[s], i] += w
            D[idx[s], i] = 1
            per_artist[s][a] += w
    R, RT, RD = _roll(X, WINDOW), _roll(T, WINDOW), _roll(D, WINDOW)
    BX, BT = _roll(X, BASE_DAYS), _roll(T, BASE_DAYS)
    base = np.zeros_like(X)
    cum_x, cum_t = np.cumsum(X, axis=1), np.cumsum(T)
    for i in range(nd):
        j = i - BASE_SKIP
        if j >= 0 and BT[j] > 50:
            base[:, i] = BX[:, j] / BT[j]
        else:
            base[:, i] = cum_x[:, max(i - 1, 0)] / max(cum_t[max(i - 1, 0)], 1.0)
    share = np.where(RT >= 20, R / np.maximum(RT, 1e-9), 0.0)
    on = (share >= MIN_SHARE) & (share >= LIFT * np.maximum(base, 0.01)) & (R >= MIN_PLAYS) & (RD >= MIN_DAYS)
    day = lambda i: d0 + timedelta(days=int(i))  # noqa: E731
    raw: list[tuple[int, int, int, int, int | None, float]] = []  # (scéna, onset, peak, end, fade, pshare)
    for k in range(len(ids)):
        days_on = np.nonzero(on[k])[0]
        if not len(days_on):
            continue
        runs, st, pr = [], days_on[0], days_on[0]
        for x in days_on[1:]:
            if x - pr > GAP:
                runs.append((st, pr))
                st = x
            pr = x
        runs.append((st, pr))
        for a, b in runs:
            if b - a + 1 < (LIVE_MIN_LEN if b == nd - 1 else min_len):
                continue  # běžící vlna stačí kratší (roste právě teď)
            pk = a + int(share[k, a:b + 1].argmax())
            fade = next((x for x in range(pk, min(b + 60, nd)) if share[k, x] < 0.5 * share[k, pk]), None)
            raw.append((k, max(a - (WINDOW - 1), 0), pk, b, fade, float(share[k, pk])))
    raw.sort(key=lambda r: r[1])
    waves: list[Wave] = []
    last = nd - 1
    for k, onset, pk, end, fade, pshare in raw:
        sid = ids[k]
        # Souběžná vlna podobné scény = táž vlna (pop punk rozdělený do dvou scén).
        twin = next(
            (w for w in waves if sims is not None and w.end >= day(onset) and (sims(w.scene, sid) or 0) >= SIBLING_SIM),
            None,
        )
        if twin is not None:
            twin.scenes.append(sid)
            twin.end = max(twin.end, day(end))
            continue
        now_share = float(share[k, last])
        if day(end) < day(last) - timedelta(days=ENDED_AFTER_DAYS) or now_share < ENDED_RATIO * pshare and day(end) < day(last):
            state = "ended"
        elif (last - pk >= FADING_AFTER_PEAK and now_share <= FADING_RATIO * pshare) or end < last:
            state = "fading"
        elif last - pk <= 3:
            state = "rising" if now_share < pshare else "peak"
        else:
            state = "peak"
        top = [a for a, _ in per_artist[sid].most_common(5)]
        waves.append(Wave([sid], day(onset), day(pk), day(end), day(fade) if fade is not None else None, pshare, now_share, state, top))
    # Typ posluchače z posledních 2 let.
    hist_from = max(0, nd - HISTORY_DAYS)
    active = [i for i in listening_days if i >= hist_from]
    in_wave = set()
    for w in waves:
        a, b = (w.onset - d0).days, (w.end - d0).days
        in_wave |= {i for i in active if a <= i <= b}
    wave_share = len(in_wave) / max(1, len(active))
    recent_waves = [w for w in waves if (w.end - d0).days >= hist_from]
    months = []
    for m0 in range(hist_from, nd, 30):
        col = X[:, m0:m0 + 30].sum(axis=1)
        tot = col.sum()
        if tot >= 30:
            months.append(int((col / tot >= 0.03).sum()))
    per_month = float(np.median(months)) if months else 0.0
    totals = X[:, hist_from:].sum(axis=1)
    top_share = float(totals.max() / totals.sum()) if totals.sum() else 0.0
    if len(active) < 180 or len(months) < 12:
        listener = "unknown"
    elif per_month <= 4 or top_share >= 0.4:
        listener = "steady"
    elif wave_share >= 0.45 and len(recent_waves) >= 4 and per_month >= 6:
        listener = "wave"
    else:
        listener = "mixed"
    return WaveReport(waves, listener, wave_share, per_month, top_share)
