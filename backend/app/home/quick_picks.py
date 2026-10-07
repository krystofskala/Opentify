"""Rychlý výběr na Domů: připnuté playlisty (max 6) + chytré doplnění podle
toho, co profil obvykle pouští v tuhle denní dobu.

Chytré pořadí (bez připnutých):
- poslechy za posledních 90 dní vážené podobností hodiny (kolem teď, ±1,5 h
  Gaussovsky, přes půlnoc), typem dne (všední / víkend) a stářím (poločas
  3 týdny);
- playlist dostane body za to, kolikrát se z něj (kontext poslechu
  "/playlists/<id>", "/library/liked") v podobnou dobu hrálo, a za to, jak
  moc jeho interpreti odpovídají tomu, co v tuhle dobu posloucháš -- ráno
  tak vyjde jiný mix než večer i u mixů, které jsi nikdy nespustil;
- vybírá ze všeho (i ze sekcí, které má profil na Domů skryté); ze
  žebříčků a nálad nejvýš jedno místo (`WIDE_SLOTS`) -- ten, který na vkus
  a denní dobu sedí nejvíc (něco mimo bublinu, ale ne zaplavit);
- bez historie zůstává původní pořadí (mixy, žebříčky, výběry).
"""

from __future__ import annotations

import math
from collections import Counter
from datetime import timedelta
from zoneinfo import ZoneInfo

from sqlmodel import Session, select

from app.models import HomeSnapshot, Listen, Playlist, PlaylistItem, Recording
from app.utils import utcnow

MAX_PINS = 6
QUICK_SIZE = 6
# Žebříčky a nálady: jedno místo pro něco mimo vlastní vkus ("Top Worldwide
# jako jedno místo ho neodradí, třeba zaujme").
WIDE_SLOTS = 1
_TZ = ZoneInfo("Europe/Prague")


def pins_key(user_id: str) -> str:
    return f"quick_pins:{user_id}"


def get_pins(session: Session, user_id: str) -> list[str]:
    row = session.get(HomeSnapshot, pins_key(user_id))
    return list((row.payload or {}).get("ids") or []) if row else []


def set_pins(session: Session, user_id: str, ids: list[str]) -> list[str]:
    ids = list(dict.fromkeys(ids))[:MAX_PINS]
    row = session.get(HomeSnapshot, pins_key(user_id)) or HomeSnapshot(key=pins_key(user_id))
    row.payload = {"ids": ids}
    row.generated_at = utcnow()
    session.add(row)
    session.commit()
    return ids


def _aware(dt):
    from datetime import timezone

    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def time_profile(session: Session, user_id: str) -> tuple[Counter, Counter, Counter]:
    """(váha kontextu, váha interpreta, váha skladby) pro TEĎ."""
    now = utcnow()
    local_now = now.astimezone(_TZ)
    hour_now = local_now.hour + local_now.minute / 60
    weekend_now = local_now.weekday() >= 5
    from app.home.activation import excluded_sources

    off = excluded_sources(user_id)  # zdroje vypnuté ze vkusu (Profil › Hudba)
    rows = [
        (rid, played_at, context)
        for rid, played_at, context, source in session.exec(
            select(Listen.recording_id, Listen.played_at, Listen.context, Listen.source).where(
                Listen.user_id == user_id, Listen.played_at >= now - timedelta(days=90)
            )
        ).all()
        if source not in off
    ]
    ctx: Counter = Counter()
    rec_w: Counter = Counter()
    for rid, played_at, context in rows:
        played = _aware(played_at)
        local = played.astimezone(_TZ)
        dh = abs(local.hour + local.minute / 60 - hour_now)
        dh = min(dh, 24 - dh)
        w = math.exp(-(dh * dh) / (2 * 1.5 * 1.5))
        w *= 1.0 if (local.weekday() >= 5) == weekend_now else 0.5
        w *= 0.5 ** ((now - played).total_seconds() / 86400 / 21)
        if w < 0.01:
            continue
        if context and context.startswith("/"):  # cesta v appce, ne "spotify:clickrow" z importu
            ctx[context] += w
        rec_w[rid] += w
    artists: Counter = Counter()
    ids = list(rec_w)
    for i in range(0, len(ids), 500):
        for rid, artist_id in session.exec(
            select(Recording.id, Recording.artist_id).where(Recording.id.in_(ids[i : i + 500]))  # type: ignore[attr-defined]
        ).all():
            if artist_id:
                artists[artist_id] += rec_w[rid]
    return ctx, artists, rec_w


def rank(session: Session, user_id: str, candidates: list[Playlist], liked_id: str | None) -> list[Playlist]:
    """Kandidáti seřazení podle toho, jak sedí na tuhle denní dobu."""
    return [p for p, _score in rank_scored(session, user_id, candidates, liked_id)]


def rank_scored(
    session: Session, user_id: str, candidates: list[Playlist], liked_id: str | None
) -> list[tuple[Playlist, float | None]]:
    """Jako `rank`, i se skóre shody (0..1,7); bez historie skóre None."""
    ctx, artists, _recs = time_profile(session, user_id)
    if not ctx and not artists:
        return [(p, None) for p in candidates]
    max_ctx = max(ctx.values(), default=0) or 1.0
    max_art = max(artists.values(), default=0) or 1.0
    scored = []
    for order, p in enumerate(candidates):
        c = ctx.get(f"/playlists/{p.id}", 0.0)
        if p.id == liked_id:
            c += ctx.get("/library/liked", 0.0)
        items = session.exec(
            select(Recording.artist_id)
            .join(PlaylistItem, PlaylistItem.recording_id == Recording.id)
            .where(PlaylistItem.playlist_id == p.id)
            .limit(60)
        ).all()
        art = sum(artists.get(a, 0.0) for a in items if a) / max(len(items), 1)
        score = c / max_ctx + 0.7 * min(1.0, art / max_art * 4)
        # Malá přednost původnímu pořadí při shodě (mixy dne napřed).
        scored.append((-score, order, p))
    scored.sort(key=lambda x: (x[0], x[1]))
    return [(p, -s) for s, _o, p in scored]
