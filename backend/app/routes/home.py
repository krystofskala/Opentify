"""`GET /home` -- celá obrazovka Domů jedním voláním ze snapshotů v DB."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends
from sqlmodel import Session, select

from app.auth import get_current_user
from app.catalog.availability import resolve_artist_name
from app.db import get_session
from app.home.generators import _covers_for
from app.models import Artist, Listen, Playlist, PlaylistItem, Recording, Release
from app.home.service import get_home, run_generators

home_router = APIRouter(prefix="/home", tags=["home"])


@home_router.get("")
async def home(current: tuple[str, str] = Depends(get_current_user)):
    user_id, _device_id = current
    return await get_home(user_id)


@home_router.get("/recent")
def recent(
    limit: int = 8,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """"Pokračovat v poslechu" nahoře na Domů -- poslední poslouchaná alba
    (u skladby bez alba skladba sama), nejnovější první. Z uložených
    poslechů, takže přežije obnovení stránky i jiné zařízení (dřív jen
    paměť klienta). Necachuje se -- má reagovat hned."""
    user_id, _device_id = current
    listens = session.exec(
        select(Listen)
        # Importovaná historie ze Spotify sem nepatří -- jen co hrálo v appce.
        .where(Listen.user_id == user_id, (Listen.source.is_(None)) | (Listen.source != "spotify-history"))  # type: ignore[union-attr]
        .order_by(Listen.played_at.desc())  # type: ignore[attr-defined]
        .limit(300)
    ).all()
    items: list[dict] = []
    seen: set[str] = set()
    for listen in listens:
        recording = session.get(Recording, listen.recording_id)
        if recording is None:
            continue
        # Přehráno z playlistu / Oblíbených / interpreta -> ta položka celá,
        # ne jednotlivé album skladby.
        context_item = _context_item(session, listen.context)
        if context_item is not None:
            key = f"c:{context_item['kind']}:{context_item['id']}"
            if key not in seen:
                seen.add(key)
                items.append(context_item)
            if len(items) >= limit:
                break
            continue
        release = session.get(Release, recording.release_id) if recording.release_id else None
        key = f"r:{release.id}" if release else f"t:{recording.id}"
        if key in seen:
            continue
        seen.add(key)
        artist_name = resolve_artist_name(session, recording.artist_id)
        if release is not None:
            image = release.images[0] if release.images else None
            items.append(
                {
                    "kind": "album",
                    "id": release.id,
                    "title": release.title,
                    "artistName": artist_name,
                    "imageUrl": image,
                    "lastRecordingId": recording.id,
                }
            )
        else:
            artist = session.get(Artist, recording.artist_id) if recording.artist_id else None
            items.append(
                {
                    "kind": "track",
                    "id": recording.id,
                    "title": recording.title,
                    "artistName": artist_name,
                    "imageUrl": artist.images[0] if artist and artist.images else None,
                    "lastRecordingId": recording.id,
                    "artistId": recording.artist_id,
                }
            )
        if len(items) >= limit:
            break
    return items


def _context_item(session: Session, context: str | None) -> dict | None:
    """Položka "Pokračovat v poslechu" z cesty, odkud se hrálo; `None` pro
    alba (řeší volající) a kontexty bez vlastní stránky (Domů, Hledat)."""
    if not context:
        return None
    parts = context.strip("/").split("/")
    if parts[:2] == ["library", "liked"]:
        return {"kind": "liked", "id": "liked", "title": "Oblíbené skladby", "artistName": "Playlist", "imageUrl": None}
    if len(parts) != 2:
        return None
    kind, ident = parts
    if kind == "playlists":
        playlist = session.get(Playlist, ident)
        if playlist is None:
            return None
        ids = session.exec(
            select(PlaylistItem.recording_id)
            .where(PlaylistItem.playlist_id == playlist.id)
            .order_by(PlaylistItem.position)  # type: ignore[arg-type]
            .limit(40)
        ).all()
        covers = list(playlist.cover_urls or []) or _covers_for(list(ids))
        return {
            "kind": "playlist",
            "id": playlist.id,
            "title": playlist.title,
            "artistName": "Playlist",
            "imageUrl": covers[0] if covers else None,
            "imageUrls": covers[:4],
            "source": playlist.source,
        }
    if kind == "artists":
        artist = session.get(Artist, ident)
        if artist is None:
            return None
        return {
            "kind": "artist",
            "id": artist.id,
            "title": artist.name,
            "artistName": "Interpret",
            "imageUrl": artist.images[0] if artist.images else None,
        }
    return None


@home_router.post("/refresh")
async def refresh_home(force: bool = True, _current=Depends(get_current_user)):
    """Ruční přegenerování (jinak běží samo na pozadí, viz home_refresh_loop).
    Všechny generátory trvají ~3 min -- běží na pozadí, request hned vrátí."""
    asyncio.create_task(run_generators(force=force))
    return {"started": True, "force": force}
