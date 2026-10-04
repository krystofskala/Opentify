"""Offline test vkusu: jak dobře model k danému dni předpoví, co profil
opravdu poslouchal další týden. Porovná dnešní model (posledních 365 dní,
počet poslechů + čerstvost) s novým (app/home/activation.py).

Jen čte; nic neukládá. `python -m app.tools.taste_replay [user_id] [počet_dní]`
"""

from __future__ import annotations

import json
import math
import random
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone

from sqlmodel import Session, select

from app.db import engine
from app.home import activation as av
from app.models import Listen, Recording


def _rows(user_id: str):
    with Session(engine) as session:
        rows = session.exec(select(Listen.recording_id, Listen.played_at).where(Listen.user_id == user_id)).all()
        ids = list({r for r, _ in rows})
        artist_of: dict[str, str] = {}
        for i in range(0, len(ids), 500):
            for rid, aid in session.exec(
                select(Recording.id, Recording.artist_id).where(Recording.id.in_(ids[i : i + 500]))  # type: ignore[attr-defined]
            ).all():
                if aid:
                    artist_of[rid] = aid
    return [(r, av._aware(p)) for r, p in rows], artist_of


def _baseline(rows, artist_of, day: datetime):
    """Dnešní load_taste (bez lajků/knihovny, ty jsou stav dneška): 365 dní,
    +1 za poslech, +2·e^(−dní/30) za čerstvost skladby."""
    counts: Counter = Counter()
    last: dict[str, datetime] = {}
    for rid, played in rows:
        if day - timedelta(days=365) <= played < day:
            counts[rid] += 1
            if rid not in last or played > last[rid]:
                last[rid] = played
    artists: Counter = Counter()
    for rid, n in counts.items():
        a = artist_of.get(rid)
        if a:
            artists[a] += n + 2.0 * math.exp(-(day - last[rid]).days / 30)
    return artists, counts


def _recall(ranked: list[str], truth: Counter) -> float:
    """Podíl poslechů příštího týdne, které padly na top-N položky."""
    total = sum(truth.values()) or 1
    top = set(ranked)
    return sum(n for k, n in truth.items() if k in top) / total


def evaluate(user_id: str, points: int = 16) -> dict:
    rows, artist_of = _rows(user_id)
    if not rows:
        return {"error": "žádné poslechy"}
    newest = max(p for _r, p in rows)
    days = [newest - timedelta(days=8 + 45 * i) for i in range(points)]
    variants = {
        "dnes (365 d)": None,
        "nový: ARTIST_BLEND (dlouhý 0,5 + střední 0,3 + krátký 0,2)": av.ARTIST_BLEND,
        "nový: jen střední (známé skladby)": {"medium": 1.0},
        "nový: jen dlouhý (celá historie)": {"long": 1.0},
    }
    res: dict[str, dict[str, list[float]]] = {v: {"artists@50": [], "repeats@100": []} for v in variants}
    rng = random.Random(1)
    used = 0
    for day in days:
        week = [(r, p) for r, p in rows if day <= p < day + timedelta(days=7)]
        before = [(r, p) for r, p in rows if p < day]
        if len(week) < 20 or len(before) < 200:
            continue
        used += 1
        heard_before = {r for r, _ in before}
        truth_artists = Counter(artist_of[r] for r, _ in week if r in artist_of)
        truth_repeats = Counter(r for r, _ in week if r in heard_before)
        act = av.compute(user_id, now=day, before=day)
        base_artists, base_counts = _baseline(rows, artist_of, day)
        for name, weights in variants.items():
            if weights is None:
                artists = [a for a, _ in base_artists.most_common(50)]
                # Dnešní Denní mix bere známé skladby náhodně ze slyšených za rok.
                pool = list(base_counts)
                rng.shuffle(pool)
                tracks = pool[:100]
            else:
                artists = [a for a, _ in act.blend(weights).most_common(50)]
                track_score: Counter = Counter()
                for profile, w in weights.items():
                    vals = getattr(act, profile)
                    top = max(vals.values(), default=0) or 1.0
                    for rid, v in vals.items():
                        track_score[rid] += w * v / top
                tracks = [r for r, _ in track_score.most_common(100)]
            res[name]["artists@50"].append(_recall(artists, truth_artists))
            res[name]["repeats@100"].append(_recall(tracks, truth_repeats))
    summary = {
        name: {k: round(sum(v) / len(v), 3) if v else None for k, v in m.items()} for name, m in res.items()
    }
    return {"user": user_id, "testDays": used, "results": summary}


def main() -> None:
    user_id = sys.argv[1] if len(sys.argv) > 1 else "demo-user"
    points = int(sys.argv[2]) if len(sys.argv) > 2 else 16
    started = datetime.now(timezone.utc)
    out = evaluate(user_id, points)
    out["seconds"] = round((datetime.now(timezone.utc) - started).total_seconds())
    print(json.dumps(out, ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
