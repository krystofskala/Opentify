"""`GET /home` -- celá obrazovka Domů jedním voláním ze snapshotů v DB."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select

from app.auth import get_current_user
from app.catalog.availability import resolve_artist_name
from app.db import engine, get_session
from app.home.generators import _covers_for
from app.models import Artist, Listen, Playlist, PlaylistItem, Recording, Release
from app.library.spotify_history import IMPORTED_SOURCES
from app.home.service import _accent_for, _art_style, get_home, run_generators

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
        .where(Listen.user_id == user_id, (Listen.source.is_(None)) | (Listen.source.notin_(IMPORTED_SOURCES)))  # type: ignore[union-attr]
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
            # Stejný generativní obal jako karta na Domů (design audit #1).
            "accentColor": _accent_for(playlist.source),
            "artStyle": _art_style(playlist.source),
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


class HomeGenresIn(BaseModel):
    ids: list[str]


@home_router.get("/genres")
def home_genres(current: tuple[str, str] = Depends(get_current_user)):
    """Žánry na výběr pro řady na Domů a ty, co má profil připnuté."""
    from app import browse

    return {
        "available": [
            {"id": c.id, "title": c.title, "color": c.color} for c in browse.CATEGORIES if c.group == "genre"
        ],
        "selected": [c.id for c in browse.pinned_genres(current[0])],
    }


@home_router.put("/genres")
async def set_home_genres(body: HomeGenresIn, current: tuple[str, str] = Depends(get_current_user)):
    from app import browse
    from app.home.service import invalidate_home_cache
    from app.models import AppUser

    ids = [i for i in dict.fromkeys(body.ids) if (c := browse.get_category(i)) is not None and c.group == "genre"]
    with Session(engine) as session:
        user = session.get(AppUser, current[0])
        if user is not None:
            user.home_genres = ids
            session.add(user)
            session.commit()

    async def warm() -> None:
        for i in ids:
            c = browse.get_category(i)
            if c is not None:
                await browse.genre_rail(c)
                await browse.genre_new_releases(c)  # novinky (bluegrass) hned, ne až za hodinu
                try:
                    await browse.build_showcase(c)  # vitrína žánru na Domů hned
                except Exception:  # noqa: BLE001
                    pass
        await invalidate_home_cache()

    asyncio.create_task(warm())
    await invalidate_home_cache()
    return {"selected": ids}


def _pin_target(session: Session, user_id: str, playlist_id: str) -> str:
    """'liked' = Oblíbené profilu; jinak playlist, který profil vidí."""
    from app.library.spotify_import import get_or_create_liked_songs_playlist
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistMember

    if playlist_id == "liked":
        return get_or_create_liked_songs_playlist(session, user_id).id
    p = session.get(Playlist, playlist_id)
    if p is None:
        raise HTTPException(status_code=404, detail="playlist neexistuje")
    member = session.exec(
        select(PlaylistMember).where(PlaylistMember.playlist_id == p.id, PlaylistMember.user_id == user_id)
    ).first()
    if p.owner_user_id not in (user_id, GLOBAL_PLAYLIST_OWNER) and member is None:
        raise HTTPException(status_code=403, detail="cizí playlist")
    return p.id


@home_router.get("/quick-pins")
def quick_pins(current: tuple[str, str] = Depends(get_current_user)):
    """Playlisty připnuté do Rychlého výběru (max 6, v pořadí)."""
    from app.home import quick_picks as qp
    from app.library.spotify_import import get_or_create_liked_songs_playlist

    with Session(engine) as session:
        ids = qp.get_pins(session, current[0])
        liked = get_or_create_liked_songs_playlist(session, current[0]).id
    return {"ids": ids, "likedId": liked, "max": qp.MAX_PINS}


@home_router.put("/quick-pins/{playlist_id}")
async def pin_quick(playlist_id: str, current: tuple[str, str] = Depends(get_current_user)):
    from app.home import quick_picks as qp
    from app.home.service import invalidate_home_cache

    with Session(engine) as session:
        pid = _pin_target(session, current[0], playlist_id)
        ids = qp.get_pins(session, current[0])
        if pid not in ids:
            if len(ids) >= qp.MAX_PINS:
                raise HTTPException(status_code=409, detail=f"Připnout jde nejvýš {qp.MAX_PINS} playlistů.")
            ids = qp.set_pins(session, current[0], [*ids, pid])
    await invalidate_home_cache()
    return {"ids": ids}


@home_router.delete("/quick-pins/{playlist_id}")
async def unpin_quick(playlist_id: str, current: tuple[str, str] = Depends(get_current_user)):
    from app.home import quick_picks as qp
    from app.home.service import invalidate_home_cache

    with Session(engine) as session:
        pid = _pin_target(session, current[0], "liked") if playlist_id == "liked" else playlist_id
        ids = qp.set_pins(session, current[0], [i for i in qp.get_pins(session, current[0]) if i != pid])
    await invalidate_home_cache()
    return {"ids": ids}


_refresh_running = False


@home_router.post("/refresh")
async def refresh_home(force: bool = False, current=Depends(get_current_user)):
    """Ruční přegenerování (jinak běží samo na pozadí, viz home_refresh_loop).
    Všechny generátory trvají ~3 min -- běží na pozadí, request hned vrátí.
    Vynucené (všechno znovu) jen admin; nikdy dvakrát souběžně."""
    global _refresh_running
    from app.auth import ADMIN_ID

    force = force and current[0] == ADMIN_ID
    if _refresh_running:
        return {"started": False, "running": True}

    async def run() -> None:
        global _refresh_running
        _refresh_running = True
        try:
            await run_generators(force=force)
        finally:
            _refresh_running = False

    asyncio.create_task(run())
    return {"started": True, "force": force}
