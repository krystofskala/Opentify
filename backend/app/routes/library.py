"""REST routy pro osobní knihovnu — `/library/*`:

  - `POST /library/scan`           -- spustí sken lokálních souborů (MUSIC_DIR) na pozadí.
  - `GET  /library/scan/status`    -- průběh běžícího/posledního skenu.
  - `GET  /library/local-tracks`   -- naskenované lokální soubory, rovnou přehratelné.
  - `POST /library/import/spotify` -- naimportuje Spotify export (ZIP/JSON).
  - `GET  /library/liked-songs`    -- vrátí naimportované/lokální "Liked Songs".

Na rozdíl od `routes/catalog.py`/`routes/recommendations.py` (tenká vrstva
nad *Service třídou) tu logika žije rovnou v `app.library.*` modulech --
sken/import nemají žádný externí API klient, který by bylo potřeba injektovat
přes `Depends`, takže samostatná service třída by byla jen obálka navíc.
"""

from __future__ import annotations

import asyncio
import json
import os
import zipfile
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile
from sqlmodel import Session, select

from app.auth import get_current_user
from app.catalog.availability import compute_availability
from app.catalog.schemas import RecordingOut
from app.db import engine, get_session
from app.library.scanner import ScanProgress, get_scan_progress, scan_library
from app.library.spotify_import import LIKED_SONGS_SOURCE, LIKED_SONGS_TITLE, import_spotify_library
from app.models import MediaAsset, Playlist, PlaylistItem, PlaylistKind, Recording

library_router = APIRouter(prefix="/library", tags=["library"])

# Kontejnerová cesta je pevná (bind mount cíl v docker-compose.yml) -- co se
# mění mezi Windows vývojem a Linux serverem, je jen `MUSIC_DIR` (hostitelská
# strana mountu), kód se nedotkne.
LOCAL_MUSIC_ROOT = Path(os.environ.get("LOCAL_MUSIC_ROOT", "/data/local-music"))


def _progress_dict(p: ScanProgress) -> dict:
    return {
        "status": p.status,
        "root": p.root,
        "totalFiles": p.total_files,
        "scanned": p.scanned,
        "matchedMusicbrainz": p.matched_musicbrainz,
        "matchedLocal": p.matched_local,
        "alreadyScanned": p.already_scanned,
        "skippedNoTags": p.skipped_no_tags,
        "errors": p.errors,
        "errorMessage": p.error_message,
    }


@library_router.post("/scan")
async def scan(_current: tuple[str, str] = Depends(get_current_user)):
    progress = get_scan_progress()
    if progress.status == "running":
        # Už jeden běží (např. po refreshi stránky) -- jen vrať jeho stav,
        # nezakládej druhý souběžný sken.
        return _progress_dict(progress)

    async def _run() -> None:
        # Vlastní DB session -- request-scoped `Depends(get_session)` by se
        # zavřela hned po návratu z tohohle handleru, sken ale běží dál jako
        # samostatná asyncio úloha (MusicBrainz limituje na 1 req/s, tisíce
        # souborů by se v jednom HTTP requestu dávno nestihly).
        with Session(engine) as session:
            await scan_library(session, LOCAL_MUSIC_ROOT)

    asyncio.create_task(_run())
    return {"status": "started", "root": str(LOCAL_MUSIC_ROOT)}


@library_router.get("/scan/status")
def scan_status(_current: tuple[str, str] = Depends(get_current_user)):
    return _progress_dict(get_scan_progress())


@library_router.get("/local-tracks")
def local_tracks(
    limit: int = Query(default=100, ge=1, le=500),
    offset: int = Query(default=0, ge=0),
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    """Nahrávky naskenované z lokální knihovny (`POST /library/scan`) --
    `MediaAsset.status` je u nich vždy `AVAILABLE` bez provisioningu, takže
    jde v klientu o obrazovku "přehraj rovnou"."""
    base_query = select(MediaAsset).where(MediaAsset.source_provider.in_(["local", "musicbrainz-local"]))
    total = len(session.exec(base_query).all())
    assets = session.exec(
        base_query.order_by(MediaAsset.updated_at.desc()).offset(offset).limit(limit)
    ).all()

    items: list[RecordingOut] = []
    for asset in assets:
        recording = session.get(Recording, asset.recording_id)
        if recording is None:
            continue
        items.append(
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

    return {"total": total, "items": [i.model_dump(by_alias=True) for i in items]}


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
    except (json.JSONDecodeError, zipfile.BadZipFile) as exc:
        raise HTTPException(
            status_code=400,
            detail="Nepodařilo se rozpoznat formát -- očekává se ZIP s CSV playlisty nebo `YourLibrary.json`.",
        ) from exc
    return {
        "totalInFile": result.total_in_file,
        "matched": result.matched,
        "alreadyPresent": result.already_present,
        "skipped": result.skipped,
        "playlistsImported": result.playlists_imported,
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
