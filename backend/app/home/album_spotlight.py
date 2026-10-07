"""Album na celý poslech -- jedno album denně na Domů nového profilu.

- Bez dat: střídá se po dnech napříč žánry (Last.fm nejposlouchanější alba
  žánru, celé desky, ne singly).
- S prvními poslechy / srdíčky / startem Pusť teď: album interpreta, kterého
  člověk slyšel nebo zadal (nejposlouchanější deska, kterou ještě neslyšel).

Snímek `album_spotlight:<profil>` = {"date", "releaseId", "reason"}; Domů ho
jen čte, sestavuje se na pozadí (dotazy ven) a mění se jednou denně.
"""

from __future__ import annotations

import asyncio
import hashlib
import logging
from datetime import date
from typing import Any

from sqlmodel import Session, select

from app.db import engine

logger = logging.getLogger(__name__)

# Žánr (štítek Last.fm) -> český název do důvodu.
GENRES: list[tuple[str, str]] = [
    ("rock", "rocku"), ("folk", "folku"), ("jazz", "jazzu"), ("electronic", "elektroniky"),
    ("hip-hop", "hip hopu"), ("soul", "soulu"), ("indie", "indie"), ("blues", "blues"),
    ("bluegrass", "bluegrassu"), ("classical", "vážné hudby"), ("pop", "popu"), ("metal", "metalu"),
    ("singer-songwriter", "písničkářů"), ("punk", "punku"), ("country", "country"), ("ambient", "ambientu"),
]

_running: dict[str, asyncio.Task] = {}


def key(user_id: str) -> str:
    return f"album_spotlight:{user_id}"


def current(session: Session, user_id: str) -> dict[str, Any] | None:
    from app.models import HomeSnapshot

    snap = session.get(HomeSnapshot, key(user_id))
    return dict(snap.payload or {}) if snap and snap.payload else None


def fresh(payload: dict[str, Any] | None) -> bool:
    return bool(payload and payload.get("date") == date.today().isoformat() and payload.get("releaseId"))


def _seed_artists(user_id: str) -> list[str]:
    """Jména interpretů, které člověk slyšel nebo má rád (nejnovější první)."""
    from app.home.play_now import _chosen_tracks
    from app.models import Artist, Listen, Recording

    with Session(engine) as session:
        rids = list(
            session.exec(
                select(Listen.recording_id).where(Listen.user_id == user_id).order_by(Listen.played_at.desc()).limit(50)  # type: ignore[attr-defined]
            ).all()
        )
        rids += _chosen_tracks(session, user_id, 50)
        names: list[str] = []
        for rid in dict.fromkeys(rids):
            rec = session.get(Recording, rid)
            artist = session.get(Artist, rec.artist_id) if rec and rec.artist_id else None
            if artist and artist.name not in names:
                names.append(artist.name)
            if len(names) >= 5:
                break
    return names


def _heard_album_titles(user_id: str) -> set[str]:
    from app.catalog.artwork import _normalize
    from app.models import Listen, Recording, Release

    with Session(engine) as session:
        return {
            _normalize(t)
            for t in session.exec(
                select(Release.title)
                .join(Recording, Recording.release_id == Release.id)  # type: ignore[arg-type]
                .join(Listen, Listen.recording_id == Recording.id)  # type: ignore[arg-type]
                .where(Listen.user_id == user_id)
            ).all()
        }


def _day_index(user_id: str, n: int) -> int:
    """Stejné po celý den, jiné pro každý profil."""
    h = int(hashlib.sha1(f"{user_id}:{date.today().isoformat()}".encode()).hexdigest(), 16)
    return h % n


async def build(user_id: str) -> dict[str, Any] | None:
    from app import browse
    from app.catalog import lastfm
    from app.catalog.artwork import _normalize

    heard = await asyncio.to_thread(_heard_album_titles, user_id)
    artists = await asyncio.to_thread(_seed_artists, user_id)
    release_id, reason = None, ""
    for name in artists:
        try:
            albums = await lastfm.top_albums(name, 8)
        except Exception:  # noqa: BLE001
            continue
        fresh_albums = [a for a in albums if a.get("title") and _normalize(a["title"]) not in heard]
        if not fresh_albums:
            continue
        ids = await browse._resolve_albums([{"artist": name, "title": a["title"]} for a in fresh_albums[:3]], 1)
        if ids:
            release_id, reason = ids[0], f"Od {name} – celé album, jak bylo myšlené"
            break
    if release_id is None:
        start = _day_index(user_id, len(GENRES))
        for i in range(len(GENRES)):
            tag, label = GENRES[(start + i) % len(GENRES)]
            try:
                albums = await lastfm.tag_top_albums(tag, 20)
            except Exception:  # noqa: BLE001
                continue
            if not albums:
                continue
            pick = _day_index(user_id + tag, min(10, len(albums)))
            ordered = albums[pick:] + albums[:pick]
            ids = await browse._resolve_albums(ordered[:4], 1)
            if ids:
                release_id, reason = ids[0], f"Klasika {label} – poslechni si ji celou"
                break
    if release_id is None:
        return None
    payload = {"date": date.today().isoformat(), "releaseId": release_id, "reason": reason}
    from app.models import HomeSnapshot
    from app.utils import utcnow

    with Session(engine) as session:
        row = session.get(HomeSnapshot, key(user_id)) or HomeSnapshot(key=key(user_id))
        row.payload = payload
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    try:
        from app.home.service import invalidate_home_cache_for

        await invalidate_home_cache_for(user_id)
    except Exception:  # noqa: BLE001
        pass
    return payload


def ensure(user_id: str) -> None:
    """Sestavit na pozadí, pokud dnešní ještě není (jedno naráz na profil)."""
    task = _running.get(user_id)
    if task is not None and not task.done():
        return
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return

    async def run() -> None:
        try:
            await build(user_id)
        except Exception:  # noqa: BLE001
            logger.exception("album na celý poslech: %s", user_id[:8])

    _running[user_id] = loop.create_task(run())
