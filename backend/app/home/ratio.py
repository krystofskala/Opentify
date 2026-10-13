"""Kolik nového -- samoladění a druhá šance (13. 10., rešerše poměrů 7t).

Samoladění: jednou týdně se podle toho, jak profil přeskakuje nové skladby
z Pusť teď oproti známým, posune podíl nových o ±5 bodů -- nejvýš ±15 od
zvolené úrovně, nikdy pod 10 %. Bez aspoň 40 přehrání nových za 4 týdny se
nic nemění (málo dat). Spotify ve svém testu viděl, že spokojenost drží do
~20 % nových a pak pozvolna klesá -- kdo nové dohrává jako známé, snese víc.

Druhá šance: nová skladba dohraná, ale bez návratu se do 2 týdnů nabídne
ještě jednou nebo dvakrát (zájem o novou skladbu roste s pár poslechy,
37 % "neutrálních" se po opakování líbí).
"""

from __future__ import annotations

from collections import Counter
from datetime import datetime, timedelta

from sqlmodel import Session, func, select

from app.db import engine
from app.library.spotify_import import LIKED_SONGS_SOURCE
from app.models import HomeSnapshot, Listen, PlayEvent, Playlist, PlaylistItem, RecBatchItem
from app.utils import utcnow

STEP = 0.05
MAX_OFFSET = 0.15
MIN_SHARE = 0.10
MIN_NEW_PLAYS = 40
WINDOW_DAYS = 28
# Nové přeskakované nejvýš o tolik víc než známé = sedí, přidat; o tolik
# a víc = moc, ubrat.
OK_GAP = 0.10
BAD_GAP = 0.30
CHANCE_DAYS = 14
CHANCE_OFFERS = 3  # původní nabídka + 2 druhé šance
_NEW_SLOTS = ("new", "explore")


def _key(user_id: str) -> str:
    return f"discovery-adapt:{user_id}"


def _week(now: datetime) -> str:
    y, w, _ = now.isocalendar()
    return f"{y}-W{w:02d}"


def skip_rates(user_id: str, now: datetime | None = None) -> tuple[int, float, int, float]:
    """(přehrání nových, podíl přeskočených, přehrání známých, podíl přeskočených)
    z Pusť teď, mixů, Objevů a rádia za posledních `WINDOW_DAYS` dní."""
    now = now or utcnow().replace(tzinfo=None)
    since = now - timedelta(days=WINDOW_DAYS)
    with Session(engine) as session:
        rows = session.exec(
            select(PlayEvent.rec_slot, PlayEvent.end_reason)
            .where(PlayEvent.user_id == user_id, PlayEvent.started_at >= since, PlayEvent.rec_slot != None)  # noqa: E711
        ).all()
        # + mixy, Objevy, rádio (audit 13. 10.: z Pusť teď samotného měla dost
        # dat jen Máma): nová = do té doby ji profil neslyšel.
        mixed = session.exec(
            select(PlayEvent.recording_id, PlayEvent.started_at, PlayEvent.end_reason)
            .where(
                PlayEvent.user_id == user_id, PlayEvent.started_at >= since, PlayEvent.rec_slot == None,  # noqa: E711
                PlayEvent.algorithmic == True, PlayEvent.origin == "connect",  # noqa: E712
            )
        ).all()
        firsts: dict[str, datetime] = {}
        ids = list({r for r, _t, _e in mixed})
        for i in range(0, len(ids), 500):
            firsts.update(session.exec(
                select(Listen.recording_id, func.min(Listen.played_at))
                .where(Listen.user_id == user_id, Listen.recording_id.in_(ids[i:i + 500]))  # type: ignore[union-attr]
                .group_by(Listen.recording_id)
            ).all())
    plays: Counter = Counter()
    skips: Counter = Counter()
    for slot, reason in rows:
        kind = "new" if slot in _NEW_SLOTS else "familiar"
        plays[kind] += 1
        skips[kind] += reason == "skipped"
    for rid, started, reason in mixed:
        first = firsts.get(rid)
        kind = "new" if first is None or first >= started - timedelta(minutes=2) else "familiar"
        plays[kind] += 1
        skips[kind] += reason == "skipped"
    rate = lambda k: skips[k] / plays[k] if plays[k] else 0.0  # noqa: E731
    return plays["new"], rate("new"), plays["familiar"], rate("familiar")


def next_offset(offset: float, new_n: int, new_skip: float, fam_n: int, fam_skip: float) -> float:
    if new_n < MIN_NEW_PLAYS or fam_n < MIN_NEW_PLAYS // 2:
        return offset
    gap = new_skip - fam_skip
    if gap <= OK_GAP:
        offset += STEP
    elif gap >= BAD_GAP:
        offset -= STEP
    return round(max(-MAX_OFFSET, min(MAX_OFFSET, offset)), 2)


def offset(user_id: str) -> float:
    """Aktuální posun podílu nových (přepočet jednou za týden)."""
    now = utcnow().replace(tzinfo=None)
    week = _week(now)
    with Session(engine) as session:
        row = session.get(HomeSnapshot, _key(user_id))
        payload = dict(row.payload or {}) if row else {}
        if payload.get("week") == week:
            return float(payload.get("offset", 0.0))
        new_n, new_skip, fam_n, fam_skip = skip_rates(user_id, now)
        value = next_offset(float(payload.get("offset", 0.0)), new_n, new_skip, fam_n, fam_skip)
        row = row or HomeSnapshot(key=_key(user_id), payload={})
        row.payload = {
            "week": week, "offset": value,
            "stats": {"new": new_n, "newSkip": round(new_skip, 3), "familiar": fam_n, "familiarSkip": round(fam_skip, 3)},
        }
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    return value


def reset(user_id: str) -> None:
    """Při změně úrovně začít od nuly -- volba uživatele má přednost."""
    with Session(engine) as session:
        row = session.get(HomeSnapshot, _key(user_id))
        if row is not None:
            session.delete(row)
            session.commit()


def new_share(base: float, user_id: str) -> float:
    try:
        return max(MIN_SHARE, base + offset(user_id))
    except Exception:  # noqa: BLE001 -- bez samoladění platí zvolená úroveň
        return base


def familiar_share(base_familiar: float, user_id: str) -> float:
    """Pro mixy, které počítají podíl známých."""
    return 1.0 - new_share(1.0 - base_familiar, user_id)


def second_chances(user_id: str, exclude: set[str], n: int = 1) -> list[str]:
    """Nové skladby z Pusť teď, které profil dohrál (ne přeskočil), sám se
    k nim nevrátil a nebyly nabídnuté víc než `CHANCE_OFFERS`-krát."""
    now = utcnow().replace(tzinfo=None)
    since = now - timedelta(days=CHANCE_DAYS)
    with Session(engine) as session:
        done = session.exec(
            select(PlayEvent.recording_id)
            .where(
                PlayEvent.user_id == user_id, PlayEvent.started_at >= since,
                PlayEvent.started_at < now - timedelta(days=1),
                PlayEvent.rec_slot.in_(_NEW_SLOTS), PlayEvent.end_reason == "completed",  # type: ignore[union-attr]
            )
            .order_by(PlayEvent.started_at.desc())  # type: ignore[attr-defined]
        ).all()
        liked = set(session.exec(
            select(PlaylistItem.recording_id)
            .join(Playlist, Playlist.id == PlaylistItem.playlist_id)
            .where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
        ).all())
        ids = [r for r in dict.fromkeys(done) if r not in exclude and r not in liked]
        if not ids:
            return []
        skipped = set(session.exec(
            select(PlayEvent.recording_id).where(
                PlayEvent.user_id == user_id, PlayEvent.recording_id.in_(ids), PlayEvent.end_reason == "skipped"  # type: ignore[attr-defined]
            )
        ).all())
        offers = dict(session.exec(
            select(RecBatchItem.recording_id, func.count())
            .where(RecBatchItem.user_id == user_id, RecBatchItem.recording_id.in_(ids))  # type: ignore[attr-defined]
            .group_by(RecBatchItem.recording_id)
        ).all())
        listens = dict(session.exec(
            select(Listen.recording_id, func.count())
            .where(Listen.user_id == user_id, Listen.recording_id.in_(ids))  # type: ignore[union-attr]
            .group_by(Listen.recording_id)
        ).all())
    out = []
    for rid in ids:
        offered = offers.get(rid, 0)
        # Víc poslechů než nabídek = vrátil se sám, už je "známá".
        if rid in skipped or offered >= CHANCE_OFFERS or listens.get(rid, 0) > offered:
            continue
        out.append(rid)
        if len(out) >= n:
            break
    return out
