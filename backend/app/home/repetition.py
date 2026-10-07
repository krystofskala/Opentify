"""Opakování napříč plochami a negativa z importu (audit 7. 10., mezera 6).

1. **Nabídnuto, nepuštěno** (Pusť teď / nekonečné hraní, z `RecBatchItem`):
   skladba, ke které přehrávání došlo a kterou člověk přeskočil (nebo
   přeskočil celou) -- ne skladby za místem, kde várku ukončil.
   - nová nabídnutá 2x za 14 dní bez poslechu -> pauza 30 dní,
   - známá nabídnutá 2x za 7 dní bez poslechu -> ztlumit na 7 dní.
   Nic se nemaže, jen počká.
2. **Přeskočení z importu** (Spotify / Apple, `PlayEvent.origin`): jen v
   kontextu algoritmu (activation.import_algorithmic -- proklikávání vlastní
   sbírky / alba je výběr) a jen za posledních 180 dní; skladba přeskočená
   aspoň 2x a nikdy nedohraná se bere jako 2x přeskočená v appce
   (SkipStreak >= 2: do mixů ne). Užitečné hlavně pro ty, kdo Spotify
   používali nedávno.
"""

from __future__ import annotations

import time
from collections import Counter, defaultdict
from datetime import timedelta

from sqlmodel import Session, select

from app.db import engine
from app.models import PlayEvent, RecBatchItem, Recording
from app.utils import utcnow

NEW_OFFERS = 2
NEW_WINDOW_DAYS = 14
NEW_PAUSE_DAYS = 30
KNOWN_OFFERS = 2
KNOWN_WINDOW_DAYS = 7
IMPORT_SKIP_DAYS = 180
IMPORT_SKIPS = 2
_CACHE_S = 600
_cache: dict[tuple[str, str], tuple[float, object]] = {}


def _cached(kind: str, user_id: str, fn):
    hit = _cache.get((kind, user_id))
    if hit and time.time() - hit[0] < _CACHE_S:
        return hit[1]
    value = fn()
    _cache[(kind, user_id)] = (time.time(), value)
    return value


def invalidate(user_id: str) -> None:
    for key in [k for k in _cache if k[1] == user_id]:
        _cache.pop(key, None)


def ignored_offers(user_id: str) -> tuple[set[str], set[str]]:
    """(nové na pauze, známé ztlumené)."""
    return _cached("offers", user_id, lambda: _ignored_offers(user_id))  # type: ignore[return-value]


def _ignored_offers(user_id: str) -> tuple[set[str], set[str]]:
    now = utcnow()
    since = (now - timedelta(days=NEW_PAUSE_DAYS + NEW_WINDOW_DAYS)).replace(tzinfo=None)
    with Session(engine) as session:
        items = session.exec(
            select(RecBatchItem).where(RecBatchItem.user_id == user_id, RecBatchItem.created_at >= since)
        ).all()
        events = session.exec(
            select(PlayEvent.recording_id, PlayEvent.end_reason, PlayEvent.rec_batch_id, PlayEvent.ended_at).where(
                PlayEvent.user_id == user_id, PlayEvent.ended_at >= since
            )
        ).all()
    listened = {rid for rid, reason, _b, _t in events if reason != "skipped"}
    played_in_batch: dict[str, dict[str, str]] = defaultdict(dict)
    for rid, reason, batch, _t in events:
        if batch:
            played_in_batch[batch][rid] = reason
    by_batch: dict[str, list[RecBatchItem]] = defaultdict(list)
    for it in items:
        by_batch[it.batch_id].append(it)
    ignored: dict[str, list[tuple[object, str]]] = defaultdict(list)  # rid -> [(kdy, slot)]
    for batch, rows in by_batch.items():
        reached = played_in_batch.get(batch, {})
        if not reached:
            continue  # várku vůbec nepustil (nebo starší appka) -- nic nesoudit
        positions = {it.recording_id: it.position for it in rows}
        last = max(positions.get(rid, -1) for rid in reached)
        for it in rows:
            if it.position <= last and reached.get(it.recording_id, "skipped") == "skipped":
                ignored[it.recording_id].append((it.created_at, it.slot))
    paused: set[str] = set()
    muted: set[str] = set()
    for rid, hits in ignored.items():
        if rid in listened:
            continue  # mezitím si ji pustil -- žádná pauza
        news = [t for t, slot in hits if slot in ("new", "explore")]
        known = [t for t, slot in hits if slot not in ("new", "explore")]
        if len(news) >= NEW_OFFERS and (now.replace(tzinfo=None) - max(news)).days < NEW_PAUSE_DAYS and (
            max(news) - min(news)
        ).days <= NEW_WINDOW_DAYS:
            paused.add(rid)
        recent_known = [t for t in known if (now.replace(tzinfo=None) - t).days < KNOWN_WINDOW_DAYS]
        if len(recent_known) >= KNOWN_OFFERS:
            muted.add(rid)
    return paused, muted


def imported_skips(user_id: str) -> set[str]:
    return _cached("import_skips", user_id, lambda: _imported_skips(user_id))  # type: ignore[return-value]


def _imported_skips(user_id: str) -> set[str]:
    from app.home import activation as av

    since = (utcnow() - timedelta(days=IMPORT_SKIP_DAYS)).replace(tzinfo=None)
    excluded = av.excluded_sources(user_id)
    with Session(engine) as session:
        rows = session.exec(
            select(PlayEvent.ended_at, PlayEvent.recording_id, PlayEvent.end_reason, PlayEvent.origin).where(
                PlayEvent.user_id == user_id,
                PlayEvent.ended_at >= since,
                PlayEvent.origin.in_(av.TASTE_SOURCES),  # type: ignore[attr-defined]
            )
        ).all()
        rows = sorted(r for r in rows if r[3] not in excluded)
        if not rows:
            return set()
        completed_ever = set(
            session.exec(
                select(PlayEvent.recording_id).where(
                    PlayEvent.user_id == user_id,
                    PlayEvent.end_reason == "completed",
                    PlayEvent.recording_id.in_({r[1] for r in rows if r[2] == "skipped"}),  # type: ignore[attr-defined]
                )
            ).all()
        )
        ids = list({r[1] for r in rows})
        meta: dict[str, tuple[str | None, str | None]] = {}
        for i in range(0, len(ids), 500):
            for rid, rel, art in session.exec(
                select(Recording.id, Recording.release_id, Recording.artist_id).where(Recording.id.in_(ids[i : i + 500]))  # type: ignore[attr-defined]
            ).all():
                meta[rid] = (rel, art)
        collection = av.collection_tracks(session, user_id)
    full = [(t, rid, *meta.get(rid, (None, None)), None) for t, rid, _r, _o in rows]
    algo = av.import_algorithmic(full, collection)
    skips: Counter = Counter(rows[k][1] for k in algo if rows[k][2] == "skipped")
    return {rid for rid, n in skips.items() if n >= IMPORT_SKIPS and rid not in completed_ever}


def recent_batch_ids(user_id: str, hours: float, batches: int) -> set[str]:
    """Skladby z posledních `batches` várek za `hours` hodin -- z databáze,
    takže paměť várek přežije restart serveru (dřív jen v paměti procesu)."""
    since = (utcnow() - timedelta(hours=hours)).replace(tzinfo=None)
    with Session(engine) as session:
        rows = session.exec(
            select(RecBatchItem.batch_id, RecBatchItem.recording_id, RecBatchItem.created_at)
            .where(RecBatchItem.user_id == user_id, RecBatchItem.created_at >= since)
            .order_by(RecBatchItem.created_at.desc())  # type: ignore[attr-defined]
        ).all()
    keep: list[str] = []
    out: set[str] = set()
    for batch, rid, _t in rows:
        if batch not in keep:
            if len(keep) >= batches:
                continue
            keep.append(batch)
        out.add(rid)
    return out
