"""Skladby, které profil "chytly" (F3, 13. 10.: "když objevím super skladbu,
ať mi to ukáže podobné a pomůže rozšířit, co se mi líbí").

Chycená skladba = za posledních `WINDOW_DAYS` dní sám pustil ve 2+ dnech a
buď je nová (první poslech do `NEW_DAYS`), nebo se k ní vrátil po dlouhé
pauze (`RETURN_GAP_DAYS`); nebo jí nedávno dal srdíčko. Z chycených pak
Pusť teď, Denní mixy a Objevy týdne berou semínka pro nové skladby -- když
chytne i něco z nových, řetěz pokračuje (vkus se rozšiřuje krok za krokem).
"""

from __future__ import annotations

from collections import Counter, defaultdict
from datetime import timedelta

from sqlmodel import Session, select

from app.db import engine

WINDOW_DAYS = 21
NEW_DAYS = 60
RETURN_GAP_DAYS = 120
LIKE_DAYS = 30
BULK_LIKES_PER_DAY = 15


def caught_tracks(user_id: str, act) -> list[str]:
    """Nejčerstvěji chycené první."""
    now = act.now
    since = now - timedelta(days=WINDOW_DAYS)
    algo = act.timeline_algo or [False] * len(act.timeline)
    days: dict[str, set] = defaultdict(set)
    last_seen: dict[str, object] = {}
    prev_before: dict[str, object] = {}
    for (t, rid), al in zip(act.timeline, algo):
        if t < since:
            prev_before[rid] = t
            continue
        if al:
            continue  # puštěné algoritmem samo nic nedokazuje
        days[rid].add(t.date())
        last_seen[rid] = t
    scored: dict[str, tuple[float, object]] = {}
    for rid, ds in days.items():
        if len(ds) < 2:
            continue
        first = act.first.get(rid)
        new = first is not None and (now - first).days <= NEW_DAYS
        prev = prev_before.get(rid)
        returned = prev is not None and (since - prev).days >= RETURN_GAP_DAYS - WINDOW_DAYS
        if new or returned:
            scored[rid] = (len(ds) + (2 if new else 1), _naive(last_seen[rid]))
    for rid, added in _recent_likes(user_id, now - timedelta(days=LIKE_DAYS)):
        if rid not in scored:
            scored[rid] = (2.0, _naive(added))
    return [r for r, _ in sorted(scored.items(), key=lambda kv: (kv[1][1], kv[1][0]), reverse=True)]


def _naive(t):
    return t.replace(tzinfo=None) if getattr(t, "tzinfo", None) else t


def _recent_likes(user_id: str, since) -> list[tuple[str, object]]:
    from app.library.spotify_import import LIKED_SONGS_SOURCE
    from app.models import Playlist, PlaylistItem

    with Session(engine) as session:
        liked = session.exec(
            select(Playlist.id).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
        ).first()
        if not liked:
            return []
        rows = session.exec(
            select(PlaylistItem.recording_id, PlaylistItem.added_at).where(
                PlaylistItem.playlist_id == liked, PlaylistItem.added_at >= since.replace(tzinfo=None)
            )
        ).all()
    # Hromadně přidané (import oblíbených ze Spotify = stovky "srdíček"
    # s dnešním datem) nejsou čerstvé objevy -- jen dny s pár srdíčky.
    per_day = Counter(added.date() for _rid, added in rows if added)
    return [(rid, added) for rid, added in rows if rid and added and per_day[added.date()] <= BULK_LIKES_PER_DAY]
