"""Sdílená mezipaměť vkusu profilu (audit 7. 10., mezera 8 -- výkon).

Vkus se dřív počítal znovu a znovu: `load_taste` (u vlastníka ~4 s) každou
hodinu pro "Na opakování" a mixy žánrů, při každé stránce stylu, denně pro
další plochy; `activation.compute` (~3 s) zvlášť pro Pusť teď, "Proč tohle?"
a stav vkusu. Teď jeden výpočet na profil, platný 15 minut:

- nové poslechy mezipaměť nezahodí (15 min stačí -- okamžité reakce v
  relaci se počítají zvlášť z PlayEvent);
- **výslovné volby ano**: srdíčko, knihovna, oblíbený interpret, nelíbí se,
  "víc / míň", přeskočení, vypnutý zdroj -- levný "otisk" se porovná při
  každém použití a když se změní, počítá se znovu.
"""

from __future__ import annotations

import threading
import time
from typing import Any, Callable

from sqlmodel import Session, func, select

from app.db import engine

TTL_S = 15 * 60
_cache: dict[tuple[str, str], tuple[float, tuple, Any]] = {}
_locks: dict[tuple[str, str], threading.Lock] = {}
_guard = threading.Lock()


def fingerprint(user_id: str) -> tuple:
    """Otisk výslovných voleb (pár COUNT/MAX dotazů, milisekundy)."""
    from app.library.spotify_import import LIKED_SONGS_SOURCE
    from app.models import (
        ArtistDislike, ArtistFeedback, FavoriteArtist, HomeSnapshot, LibraryEntry, Playlist, PlaylistItem,
        PlaylistKind, RecordingDislike, SkipStreak,
    )

    with Session(engine) as s:
        own = select(Playlist.id).where(
            Playlist.owner_user_id == user_id,
            (Playlist.source == LIKED_SONGS_SOURCE) | (Playlist.kind == PlaylistKind.USER),
        )
        items = s.exec(
            select(func.count(), func.max(PlaylistItem.position)).where(PlaylistItem.playlist_id.in_(own))  # type: ignore[attr-defined]
        ).one()
        fb = s.exec(
            select(func.count(), func.max(ArtistFeedback.updated_at), func.sum(ArtistFeedback.delta)).where(
                ArtistFeedback.user_id == user_id
            )
        ).one()
        skips = s.exec(
            select(func.count(), func.max(SkipStreak.updated_at)).where(SkipStreak.user_id == user_id, SkipStreak.streak >= 2)
        ).one()
        counts = tuple(
            s.exec(select(func.count()).select_from(m).where(m.user_id == user_id)).one()  # type: ignore[attr-defined]
            for m in (LibraryEntry, FavoriteArtist, RecordingDislike, ArtistDislike)
        )
        sources = s.get(HomeSnapshot, f"taste_sources:{user_id}")
    return (tuple(items), tuple(str(x) for x in fb), tuple(str(x) for x in skips), counts,
            tuple((sources.payload or {}).get("excluded") or []) if sources else ())


def get(kind: str, user_id: str, build: Callable[[], Any]) -> Any:
    """Hodnota z mezipaměti, nebo nově spočítaná (jeden výpočet naráz na
    profil a druh -- souběžné požadavky počkají na tentýž)."""
    key = (kind, user_id)
    fp = fingerprint(user_id)
    hit = _cache.get(key)
    if hit and time.time() - hit[0] < TTL_S and hit[1] == fp:
        return hit[2]
    with _guard:
        lock = _locks.setdefault(key, threading.Lock())
    with lock:
        hit = _cache.get(key)
        if hit and time.time() - hit[0] < TTL_S and hit[1] == fp:
            return hit[2]
        value = build()
        _cache[key] = (time.time(), fp, value)
        return value


def invalidate(user_id: str | None = None) -> None:
    for key in [k for k in _cache if user_id is None or k[1] == user_id]:
        _cache.pop(key, None)
