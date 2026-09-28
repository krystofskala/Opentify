"""REST routy pro osobní knihovnu — `/library/*`:

  - `POST /library/scan`           -- spustí sken lokálních souborů (MUSIC_DIR) na pozadí.
  - `GET  /library/scan/status`    -- průběh běžícího/posledního skenu.
  - `GET  /library/local-tracks`   -- naskenované lokální soubory, rovnou přehratelné.
  - `GET  /library/local-albums`   -- ta samá knihovna seskupená po albech.
  - `GET  /library/local-artists`  -- ta samá knihovna seskupená po interpretech.
  - `GET  /library/genres`         -- ta samá knihovna seskupená po MusicBrainz žánrech.
  - `GET  /library/by-genre/{g}`   -- skladby daného žánru.
  - `GET  /library/czech`          -- skladby interpretů s MusicBrainz `country == "CZ"`.
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
from sqlalchemy import func
from sqlmodel import Session, select

from app.auth import get_current_user
from app.catalog.availability import compute_availability, resolve_artist_name
from app.catalog.schemas import RecordingOut
from app.db import engine, get_session
from app.library.scanner import ScanProgress, get_scan_progress, scan_library
from app.library.spotify_import import (
    LIKED_SONGS_SOURCE,
    LIKED_SONGS_TITLE,
    get_or_create_liked_songs_playlist,
    import_spotify_library,
)
from app.models import Artist, MediaAsset, MediaAssetStatus, Playlist, PlaylistItem, PlaylistKind, Recording, Release

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
    """"Moje knihovna" -- cokoliv `AVAILABLE` na disku, ať už z lokálního
    skenu (`POST /library/scan`), nebo dřív obstarané přes
    `POST /tracks/{id}/provision` (slskd/YouTube). Dřív filtrovalo jen podle
    `source_provider in (local, musicbrainz-local)`, takže stažené/obstarané
    skladby v knihovně nikdy neskončily, i když je appka měla reálně na
    disku a šly rovnou přehrát -- odsud "proč to nemám v knihovně"."""
    base_query = select(MediaAsset).where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
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
                artist_name=resolve_artist_name(session, recording.artist_id),
                title=recording.title,
                duration_ms=recording.duration_ms,
                isrc=recording.isrc,
                track_number=recording.track_number,
                availability=compute_availability(session, recording.id),
                preview_url=recording.external_refs.get("previewUrl"),
            )
        )

    return {"total": total, "items": [i.model_dump(by_alias=True) for i in items]}


@library_router.get("/local-albums")
def local_albums(
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    """Alba seskupená z lokální knihovny -- jeden SQL dotaz místo N+1 dotazů
    z klienta (viz `LocalLibraryScreen` záložka "Alba"). Vrací jen alba, ke
    kterým je zaevidovaná aspoň jedna lokální nahrávka."""
    rows = session.exec(
        select(
            Release.id,
            Release.title,
            Release.images,
            Release.artist_id,
            Artist.name,
            func.count(func.distinct(Recording.id)),
        )
        .join(Recording, Recording.release_id == Release.id)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .join(Artist, Artist.id == Release.artist_id)
        .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
        .group_by(Release.id)
        .order_by(Artist.name, Release.title)
    ).all()

    return [
        {
            "id": release_id,
            "title": title,
            "coverImageUrl": images[0] if images else None,
            "artistId": artist_id,
            "artistName": artist_name,
            "trackCount": track_count,
        }
        for release_id, title, images, artist_id, artist_name, track_count in rows
    ]


@library_router.get("/local-artists")
def local_artists(
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    """Interpreti seskupení z lokální knihovny -- viz `local_albums`, stejný
    princip (jeden GROUP BY dotaz, ne N+1 z klienta)."""
    rows = session.exec(
        select(Artist.id, Artist.name, Artist.images, func.count(func.distinct(Recording.id)))
        .join(Recording, Recording.artist_id == Artist.id)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
        .group_by(Artist.id)
        .order_by(Artist.name)
    ).all()

    return [
        {
            "id": artist_id,
            "name": name,
            "imageUrl": images[0] if images else None,
            "trackCount": track_count,
        }
        for artist_id, name, images, track_count in rows
    ]


def _local_recording_out(session: Session, recording: Recording) -> RecordingOut:
    return RecordingOut(
        id=recording.id,
        mbid=recording.mbid,
        release_id=recording.release_id,
        artist_id=recording.artist_id,
        artist_name=resolve_artist_name(session, recording.artist_id),
        title=recording.title,
        duration_ms=recording.duration_ms,
        isrc=recording.isrc,
        track_number=recording.track_number,
        availability=compute_availability(session, recording.id),
        preview_url=recording.external_refs.get("previewUrl"),
    )


@library_router.get("/genres")
def local_genres(
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    """Žánry napříč lokální knihovnou (MusicBrainz genre tagy na albech, viz
    `CatalogService._enrich_release_genres` -- doplňují se líně při otevření
    alba, takže dokud se knihovna neprojde/nezobrazí, budou řídké) s počtem
    skladeb -- pohání "Podle nálady a žánru" na Home. Agregace v Pythonu, ne
    SQL GROUP BY přes JSON sloupec -- na stovkách alb zanedbatelný náklad,
    vyhne se SQLite-specific JSON1 dotazům.
    """
    rows = session.exec(
        select(Release.genres, func.count(func.distinct(Recording.id)))
        .join(Recording, Recording.release_id == Release.id)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
        .group_by(Release.id)
    ).all()

    counts: dict[str, int] = {}
    for genres, track_count in rows:
        for genre in genres or []:
            counts[genre] = counts.get(genre, 0) + track_count

    return [
        {"genre": genre, "trackCount": count}
        for genre, count in sorted(counts.items(), key=lambda kv: kv[1], reverse=True)
    ]


@library_router.get("/by-genre/{genre}")
def local_by_genre(
    genre: str,
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    """Lokální skladby, jejichž album nese daný žánr -- `genre` je přesný
    MusicBrainz genre název (viz `/library/genres`), ne fulltextové hledání."""
    matching_release_ids = {r.id for r in session.exec(select(Release)).all() if genre in (r.genres or [])}
    if not matching_release_ids:
        return {"total": 0, "items": []}

    recordings = session.exec(
        select(Recording)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .where(
            MediaAsset.status == MediaAssetStatus.AVAILABLE,
            Recording.release_id.in_(matching_release_ids),
        )
    ).all()
    items = [_local_recording_out(session, r) for r in recordings]
    return {"total": len(items), "items": [i.model_dump(by_alias=True) for i in items]}


@library_router.get("/czech")
def local_czech(
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    """Skladby interpretů s MusicBrainz `country == "CZ"` (viz
    `CatalogService._enrich_artist_country`, líné doplnění při otevření
    interpreta) -- pohání "Česká hudba" na Home."""
    recordings = session.exec(
        select(Recording)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .join(Artist, Artist.id == Recording.artist_id)
        .where(MediaAsset.status == MediaAssetStatus.AVAILABLE, Artist.country == "CZ")
    ).all()
    items = [_local_recording_out(session, r) for r in recordings]
    return {"total": len(items), "items": [i.model_dump(by_alias=True) for i in items]}


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
                artist_name=resolve_artist_name(session, recording.artist_id),
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


@library_router.post("/liked-songs/{recording_id}")
def like_song(
    recording_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Přidá nahrávku do "Liked Songs" -- stejný playlist jako Spotify import
    (`get_or_create_liked_songs_playlist`), jen jednotlivě přes UI srdíčko
    místo hromadného importu. Idempotentní -- opakované volání nic nezdvojí."""
    user_id, _device_id = current
    if session.get(Recording, recording_id) is None:
        raise HTTPException(status_code=404, detail="recording nenalezen v katalogu")

    playlist = get_or_create_liked_songs_playlist(session, user_id)
    existing = session.exec(
        select(PlaylistItem)
        .where(PlaylistItem.playlist_id == playlist.id, PlaylistItem.recording_id == recording_id)
    ).first()
    if existing is None:
        position = len(
            session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all()
        )
        session.add(PlaylistItem(playlist_id=playlist.id, recording_id=recording_id, position=position))
        session.commit()
    return {"recordingId": recording_id, "liked": True}


@library_router.delete("/liked-songs/{recording_id}")
def unlike_song(
    recording_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Opak `like_song` -- odebere z "Liked Songs", pokud tam je. Idempotentní
    (odebrání něčeho, co tam není, není chyba)."""
    user_id, _device_id = current
    playlist = session.exec(
        select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
    ).first()
    if playlist is not None:
        existing = session.exec(
            select(PlaylistItem)
            .where(PlaylistItem.playlist_id == playlist.id, PlaylistItem.recording_id == recording_id)
        ).first()
        if existing is not None:
            session.delete(existing)
            session.commit()
    return {"recordingId": recording_id, "liked": False}
