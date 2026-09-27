"""REST routy pro osobní knihovnu — `/library/*`:

  - `POST /library/scan`           -- projde lokální hudební soubory (MUSIC_DIR).
  - `POST /library/import/spotify` -- naimportuje Spotify `YourLibrary.json`.
  - `GET  /library/liked-songs`    -- vrátí naimportované/lokální "Liked Songs".

Na rozdíl od `routes/catalog.py`/`routes/recommendations.py` (tenká vrstva
nad *Service třídou) tu logika žije rovnou v `app.library.*` modulech --
sken/import nemají žádný externí API klient, který by bylo potřeba injektovat
přes `Depends`, takže samostatná service třída by byla jen obálka navíc.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from sqlmodel import Session, select

from app.auth import get_current_user
from app.catalog.availability import compute_availability
from app.catalog.schemas import RecordingOut
from app.db import get_session
from app.library.scanner import scan_library
from app.library.spotify_import import LIKED_SONGS_SOURCE, LIKED_SONGS_TITLE, import_spotify_library
from app.models import Playlist, PlaylistItem, PlaylistKind, Recording

library_router = APIRouter(prefix="/library", tags=["library"])

# Kontejnerová cesta je pevná (bind mount cíl v docker-compose.yml) -- co se
# mění mezi Windows vývojem a Linux serverem, je jen `MUSIC_DIR` (hostitelská
# strana mountu), kód se nedotkne.
LOCAL_MUSIC_ROOT = Path(os.environ.get("LOCAL_MUSIC_ROOT", "/data/local-music"))


@library_router.post("/scan")
def scan(
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    result = scan_library(session, LOCAL_MUSIC_ROOT)
    return {
        "root": str(LOCAL_MUSIC_ROOT),
        "scanned": result.scanned,
        "matched": result.matched,
        "skippedNoTags": result.skipped_no_tags,
        "errors": result.errors,
    }


@library_router.post("/import/spotify")
async def import_spotify(
    file: UploadFile,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    raw = await file.read()
    try:
        result = import_spotify_library(session, user_id, raw)
    except json.JSONDecodeError as exc:
        raise HTTPException(
            status_code=400,
            detail="Neplatný JSON -- očekává se Spotify `YourLibrary.json` export.",
        ) from exc
    return {
        "totalInFile": result.total_in_file,
        "matched": result.matched,
        "alreadyLiked": result.already_liked,
        "skipped": result.skipped,
    }


@library_router.get("/liked-songs")
def liked_songs(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    playlist = session.exec(
        select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
    ).first()
    if playlist is None:
        return {
            "id": "",
            "title": LIKED_SONGS_TITLE,
            "kind": PlaylistKind.USER.value,
            "source": LIKED_SONGS_SOURCE,
            "generatedAt": None,
            "itemCount": 0,
            "items": [],
        }

    items = session.exec(
        select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id).order_by(PlaylistItem.position)
    ).all()
    recordings: list[RecordingOut] = []
    for item in items:
        recording = session.get(Recording, item.recording_id)
        if recording is None:
            continue
        recordings.append(
            RecordingOut(
                id=recording.id,
                mbid=recording.mbid,
                release_id=recording.release_id,
                artist_id=recording.artist_id,
                title=recording.title,
                duration_ms=recording.duration_ms,
                isrc=recording.isrc,
                track_number=recording.track_number,
                availability=compute_availability(session, recording.id),
                preview_url=recording.external_refs.get("previewUrl"),
            )
        )

    return {
        "id": playlist.id,
        "title": playlist.title,
        "kind": playlist.kind.value,
        "source": playlist.source,
        "generatedAt": playlist.generated_at.isoformat() if playlist.generated_at else None,
        "itemCount": len(recordings),
        "items": [r.model_dump(by_alias=True) for r in recordings],
    }
