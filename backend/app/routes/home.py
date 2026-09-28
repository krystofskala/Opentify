"""`GET /home` -- celá obrazovka Domů jedním voláním ze snapshotů v DB."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends
from sqlmodel import Session, select

from app.auth import get_current_user
from app.catalog.availability import resolve_artist_name
from app.db import get_session
from app.models import Artist, Listen, Recording, Release
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
        select(Listen).where(Listen.user_id == user_id).order_by(Listen.played_at.desc()).limit(300)  # type: ignore[attr-defined]
    ).all()
    items: list[dict] = []
    seen: set[str] = set()
    for listen in listens:
        recording = session.get(Recording, listen.recording_id)
        if recording is None:
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


@home_router.post("/refresh")
async def refresh_home(force: bool = True, _current=Depends(get_current_user)):
    """Ruční přegenerování (jinak běží samo na pozadí, viz home_refresh_loop).
    Všechny generátory trvají ~3 min -- běží na pozadí, request hned vrátí."""
    asyncio.create_task(run_generators(force=force))
    return {"started": True, "force": force}
