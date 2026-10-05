"""Importované poslechy bez interpreta (`PendingImportPlay`) -- nic se
nezahazuje. Import je odloží (`save_pending`), generátor na pozadí
(`maintenance:pending-imports`, app/home/service.py) je po skupinách
skladba + album dohledává:

1. katalog appky -- album stejného jména s jediným interpretem (katalog
   časem roste, třeba importem ze Spotify nebo stažením alba);
2. veřejné iTunes Search (jen název skladby a alba, přes VPN proxy --
   `apple_http`), pomalu kvůli limitu Apple.

Nalezené se převedou na `Listen` (od 30 s, stejná váha jako každý poslech,
na ListenBrainz/Last.fm se neposílá) a `PlayEvent`. Nenalezené se zkusí
znovu s rostoucím odstupem (1, 2, 4... dní, nejvýš 30) -- nikdy se nesmažou.
"""

from __future__ import annotations

import asyncio
import re
from datetime import timedelta
from typing import Any

from sqlmodel import Session, delete, select

from app.db import engine
from app.models import Artist, Listen, PendingImportPlay, PlayEvent, Release
from app.utils import utcnow

MIN_PLAY_MS = 30_000
GROUPS_PER_RUN = 40  # ~2 min při pauze 3 s (Apple snese ~20 dotazů/min)
MAX_BACKOFF_DAYS = 30


def norm(text: str | None) -> str:
    return re.sub(r"[^\w]+", " ", (text or "").lower().replace("’", "'")).strip()


def save_pending(user_id: str, source: str, plays: list[dict[str, Any]]) -> int:
    """Nahradí čekající poslechy profilu z tohoto zdroje (opakovaný import
    nezdvojí). `plays` ve tvaru Spotify historie, bez interpreta."""
    from app.library.spotify_history import _parse_ts

    with Session(engine) as session:
        session.exec(delete(PendingImportPlay).where(PendingImportPlay.user_id == user_id, PendingImportPlay.source == source))
        for p in plays:
            session.add(
                PendingImportPlay(
                    user_id=user_id,
                    source=source,
                    track=p["track"],
                    album=p.get("album"),
                    played_at=_parse_ts(p["ts"]).replace(tzinfo=None),
                    played_ms=p["ms"],
                    reason_end=p.get("reason_end"),
                )
            )
        session.commit()
    return len(plays)


def _from_catalog(session: Session, album: str | None) -> str | None:
    if not album:
        return None
    names = set(session.exec(select(Artist.name).join(Release, Release.artist_id == Artist.id).where(Release.title == album)).all())
    return names.pop() if len(names) == 1 else None


async def lookup_itunes(track: str, album: str | None) -> str | None:
    """Interpret podle názvu skladby (a alba) z iTunes Search; `None`, když
    se skladba i album neshodují (raději nic než špatný interpret)."""
    import httpx

    from app.apple_http import apple_http

    client = apple_http()
    if client is None:
        return None
    try:
        resp = await client.get(
            "https://itunes.apple.com/search",
            params={"term": f"{track} {album or ''}".strip(), "entity": "song", "limit": 25, "country": "CZ"},
        )
        items = resp.json().get("results", []) if resp.status_code == 200 else []
    except (httpx.HTTPError, ValueError):
        return None
    same = [i for i in items if base(i.get("trackName")) == base(track)]
    if album:
        # Album přesně, nebo jedno je začátkem druhého ("Jazz" ~ "Jazz
        # (Deluxe Edition)"); iTunes i export přidávají k názvům přívěsky.
        same = [i for i in same if norm(i.get("collectionName")) == norm(album)] or [
            i for i in same if base(i.get("collectionName")) == base(album)
        ]
    elif same:
        same = [i for i in same if norm(i.get("trackName")) == norm(track)]  # bez alba jen přesná shoda
    return (same[0].get("artistName") or None) if same else None


def base(text: str | None) -> str:
    """Název bez přívěsků v závorkách a za pomlčkou ("Help the Poor (Live At
    The Regal Theater/1964)", "Raw Power [2023 Remaster]")."""
    cut = re.sub(r"\s*[\(\[].*?[\)\]]", "", text or "")
    return norm(re.split(r"\s+-\s+", cut)[0])


def _convert(session: Session, rows: list[PendingImportPlay], artist_name: str) -> int:
    """Čekající -> Listen (+ PlayEvent); vrátí počet nových poslechů."""
    from app.library.matching import attach_release_if_missing, find_or_create_artist, find_or_create_recording, find_or_create_release
    from app.library.spotify_history import _end_reason

    first = rows[0]
    artist = find_or_create_artist(session, artist_name)
    recording = find_or_create_recording(session, artist, first.track)
    if first.album:
        attach_release_if_missing(session, recording, find_or_create_release(session, artist, first.album))
    now, listens = utcnow(), 0
    for row in rows:
        if row.played_ms >= MIN_PLAY_MS:
            session.add(
                Listen(
                    user_id=row.user_id,
                    recording_id=recording.id,
                    played_at=row.played_at,
                    duration_played_ms=row.played_ms,
                    source=row.source,
                    lb_submitted_at=now,
                )
            )
            listens += 1
        reason = _end_reason({"ms": row.played_ms, "reason_end": row.reason_end, "skipped": False}) if row.reason_end else None
        if reason:
            session.add(
                PlayEvent(
                    user_id=row.user_id,
                    recording_id=recording.id,
                    started_at=row.played_at - timedelta(milliseconds=row.played_ms),
                    ended_at=row.played_at,
                    played_ms=row.played_ms,
                    end_reason=reason,
                    origin=row.source,
                )
            )
        session.delete(row)
    session.commit()
    return listens


async def resolve_pending(groups: int = GROUPS_PER_RUN, pause: float = 3.0) -> int:
    """Jedno kolo dohledávání (všechny profily). Vrátí počet nových poslechů."""
    now = utcnow()
    with Session(engine) as session:
        due = session.exec(
            select(PendingImportPlay).where(PendingImportPlay.next_try_at <= now).order_by(PendingImportPlay.created_at)
        ).all()
    grouped: dict[tuple[str, str | None], list[str]] = {}
    for row in due:
        key = (norm(row.track), norm(row.album) or None)
        if key in grouped or len(grouped) < groups:
            grouped.setdefault(key, []).append(row.id)
    added = 0
    for ids in grouped.values():
        with Session(engine) as session:
            rows = [r for r in (session.get(PendingImportPlay, i) for i in ids) if r is not None]
            if not rows:
                continue
            artist = _from_catalog(session, rows[0].album)
        asked_itunes = artist is None
        if artist is None:
            artist = await lookup_itunes(rows[0].track, rows[0].album)
        with Session(engine) as session:
            rows = [r for r in (session.get(PendingImportPlay, i) for i in ids) if r is not None]
            if rows and artist:
                added += _convert(session, rows, artist)
            else:
                for row in rows:
                    row.attempts += 1
                    row.next_try_at = utcnow() + timedelta(days=min(2 ** (row.attempts - 1), MAX_BACKOFF_DAYS))
                    session.add(row)
                session.commit()
        if asked_itunes:
            await asyncio.sleep(pause)
    return added


async def run() -> int:
    """Generátor `maintenance:pending-imports`."""
    return await resolve_pending()
