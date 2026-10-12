"""Paměť interpretů napříč dny pro Pusť teď (12. 10.: twenty one pilots
a Angus & Julia Stone byli ve všech 20 várkách simulace z 20).

Paměť várek a rotace hlídají jen SKLADBY -- oblíbenec s desítkami silných
písní pak prošel pokaždé jinou. Tady se počítá, kolikrát byl interpret
nabídnutý v posledních dnech (`RecBatchItem`, každé nabídnutí slábne
s poločasem `HALF_LIFE_DAYS`), a jeho šance se násobí `PER_OFFER ** váha`.
Kdo byl ve várce před chvílí, má menší šanci; po pár dnech pauzy je zpátky
naplno. Sólo projekty a kapely (Tyler Joseph <-> twenty one pilots) sdílejí
paměť přes `play_now._band_links`.
"""

from __future__ import annotations

from collections import defaultdict
from datetime import timedelta

from sqlmodel import Session, select

from app.db import engine
from app.models import RecBatchItem, Recording
from app.utils import utcnow

HALF_LIFE_DAYS = 2.0
WINDOW_DAYS = 6
PER_OFFER = 0.35
FLOOR = 0.02


def artist_weights(user_id: str) -> dict[str, float]:
    """Interpret -> součet nabídnutí v Pusť teď za posledních `WINDOW_DAYS`
    dní, každé vážené `0.5 ** (stáří_dny / HALF_LIFE_DAYS)`."""
    now = utcnow().replace(tzinfo=None)
    since = now - timedelta(days=WINDOW_DAYS)
    with Session(engine) as session:
        rows = session.exec(
            select(Recording.artist_id, RecBatchItem.created_at)
            .join(Recording, Recording.id == RecBatchItem.recording_id)  # type: ignore[arg-type]
            .where(RecBatchItem.user_id == user_id, RecBatchItem.created_at >= since)
        ).all()
    weights: dict[str, float] = defaultdict(float)
    for artist_id, created in rows:
        if not artist_id or created is None:
            continue
        age_days = max(0.0, (now - created.replace(tzinfo=None)).total_seconds() / 86400)
        weights[artist_id] += 0.5 ** (age_days / HALF_LIFE_DAYS)
    return dict(weights)


def with_links(weights: dict[str, float], links: dict[str, set[str]]) -> dict[str, float]:
    """Váha přelitá i na propojené interprety oběma směry (`links`: sólo
    interpret -> kapely, kde je členem): bere se větší z vlastní a propojené."""
    out = dict(weights)
    for artist_id, linked in links.items():
        for other in linked:
            mine, theirs = weights.get(artist_id, 0.0), weights.get(other, 0.0)
            if theirs > out.get(artist_id, 0.0):
                out[artist_id] = theirs
            if mine > out.get(other, 0.0):
                out[other] = mine
    return out


def factor(weight: float) -> float:
    return max(FLOOR, PER_OFFER**weight)
