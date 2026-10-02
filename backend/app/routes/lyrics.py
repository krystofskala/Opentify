"""REST proxy pro text skladeb ("titulky" v Now Playing screenu) — viz
`app/lyrics_service.py`. Proxy je server-side (stejně jako MusicBrainz/Deezer/
ListenBrainz), ne přímé volání LRCLIB z klienta, kvůli jednotné síťové vrstvě
a CORS."""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from app.db import get_session
from app.lyrics_service import fetch_lyrics
from app.models import Artist, MediaAsset, Recording, Release

lyrics_router = APIRouter(prefix="/lyrics", tags=["lyrics"])


@lyrics_router.get("/{recording_id}")
async def get_lyrics(recording_id: str, session: Session = Depends(get_session)):
    recording = session.get(Recording, recording_id)
    if recording is None:
        raise HTTPException(status_code=404, detail="recording nenalezen")

    artist_name = None
    aliases: list[str] = []
    if recording.artist_id:
        artist = session.get(Artist, recording.artist_id)
        artist_name = artist.name if artist else None
        # Záložní jména pro texty (Tyler Joseph -> twenty one pilots: písně
        # z jeho sólové desky jsou v databázích textů pod kapelou).
        aliases = list(((artist.external_refs or {}).get("lyricsAliases") or []) if artist else [])

    album_name = None
    if recording.release_id:
        release = session.get(Release, recording.release_id)
        album_name = release.title if release else None

    # Délka toho, co se SKUTEČNĚ přehrává (stažený soubor), ne katalogová --
    # podle ní se vybírá správně časovaná verze textu.
    asset = session.get(MediaAsset, recording.id)
    duration_ms = (asset.waveform_duration_ms if asset else None) or recording.duration_ms
    result = await fetch_lyrics(
        track_name=recording.title,
        artist_name=artist_name,
        album_name=album_name,
        duration_s=duration_ms / 1000 if duration_ms else None,
    )
    for alias in aliases:
        if result is not None:
            break
        # Délka zůstává -- jiná nahrávka dostane text bez časování, ne posunutý.
        result = await fetch_lyrics(
            track_name=recording.title,
            artist_name=alias,
            album_name=None,
            duration_s=duration_ms / 1000 if duration_ms else None,
        )
    if result is None:
        raise HTTPException(status_code=404, detail="text skladby nenalezen")
    return result
