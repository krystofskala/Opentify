"""Stálice -- klasiky, které si profil pouští bez ohledu na vlny (13. 10.:
"mixy by měly mít i klasiky, co si člověk pouští nehledě na vlny").

Stálice = skladba slyšená v aspoň `MIN_YEARS` různých letech a aspoň
`MIN_DAYS` dnech, z nichž nejvýš `MAX_BURST` připadá na jedno 60denní
okno (jinak to byla jedna vlna, ne stálice). Puštěné algoritmem se
nepočítá -- jde o vlastní návraty.
"""

from __future__ import annotations

import time
from collections import defaultdict
from datetime import timedelta

MIN_YEARS = 3
MIN_DAYS = 8
MAX_BURST = 0.5
BURST_DAYS = 60
_CACHE_S = 6 * 3600
_cache: dict[str, tuple[float, dict[str, float]]] = {}


def evergreens(user_id: str, act) -> dict[str, float]:
    """{skladba: skóre} -- víc let a dnů = vyšší."""
    hit = _cache.get(user_id)
    if hit and time.monotonic() - hit[0] < _CACHE_S:
        return hit[1]
    algo = act.timeline_algo or [False] * len(act.timeline)
    days: dict[str, set] = defaultdict(set)
    for (t, rid), al in zip(act.timeline, algo):
        if not al:
            days[rid].add(t.date())
    out: dict[str, float] = {}
    for rid, ds in days.items():
        if len(ds) < MIN_DAYS:
            continue
        years = {d.year for d in ds}
        if len(years) < MIN_YEARS:
            continue
        ordered = sorted(ds)
        j = 0
        burst = 0
        for i, d in enumerate(ordered):
            while ordered[j] < d - timedelta(days=BURST_DAYS):
                j += 1
            burst = max(burst, i - j + 1)
        if burst > MAX_BURST * len(ordered):
            continue
        out[rid] = len(ds) ** 0.5 * len(years)
    _cache[user_id] = (time.monotonic(), out)
    return out
