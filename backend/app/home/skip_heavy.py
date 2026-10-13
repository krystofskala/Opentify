"""Skladby, které profil většinou přeskakuje (audit 13. 10.: přeskakování
z importu Spotify se do vkusu skoro nepromítalo -- 545 skladeb vlastníka
s 4+ přehráními přeskočených aspoň v polovině případů; dosavadní pravidlo
bralo jen 2+ přeskočení puštěné algoritmem a nikdy dohrané, zachytilo 173).

Nejsou zakázané, jen se v Pusť teď nabízejí méně (×0,3). Počítá se z přehrání
(`PlayEvent`, appka i import historie) za posledních `WINDOW_DAYS` dní --
starý zvyk přeskakovat časem vyprchá.
"""

from __future__ import annotations

import time
from datetime import timedelta

from sqlalchemy import case, func
from sqlmodel import Session, select

from app.db import engine
from app.models import PlayEvent
from app.utils import utcnow

MIN_PLAYS = 4
SKIP_SHARE = 0.5
WINDOW_DAYS = 3 * 365
_CACHE_S = 6 * 3600
_cache: dict[str, tuple[float, set[str]]] = {}


def for_user(user_id: str) -> set[str]:
    hit = _cache.get(user_id)
    if hit and time.monotonic() - hit[0] < _CACHE_S:
        return hit[1]
    since = (utcnow() - timedelta(days=WINDOW_DAYS)).replace(tzinfo=None)
    try:
        with Session(engine) as session:
            rows = session.exec(
                select(
                    PlayEvent.recording_id,
                    func.count(),
                    func.sum(case((PlayEvent.end_reason == "skipped", 1), else_=0)),
                )
                .where(PlayEvent.user_id == user_id, PlayEvent.started_at >= since)
                .group_by(PlayEvent.recording_id)
                .having(func.count() >= MIN_PLAYS)
            ).all()
    except Exception:  # noqa: BLE001 -- doplněk, bez něj se nabízí jako dřív
        return set()
    out = {rid for rid, n, skipped in rows if n and (skipped or 0) / n >= SKIP_SHARE}
    _cache[user_id] = (time.monotonic(), out)
    return out
