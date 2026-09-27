"""Import Spotify "Your Library" exportu do lokální knihovny ("Liked Songs").

Zdroj: účet Spotify → Nastavení soukromí → "Stáhnout svá data" → v ZIPu
soubor `YourLibrary.json`, tvar `{"tracks": [{"artist", "album", "track"}]}`.
Jiné soubory z téhož exportu (`StreamingHistory*.json` s poslechovou
historií, ne "líbí se mi" seznamem) mají jiný tvar a tady se neparsují —
mimo scope prvního kroku, viz `RecommendationService.daily_jams` pro to, jak
se `Liked Songs` použije pro personalizovaný denní mix.

Matchování na katalog jede přes `app.library.matching` (jméno interpreta a
název skladby, ne MusicBrainz vyhledávání) — u stovek až tisíců položek by
živé MB dotazy narazily na rate limit; přesné přiřazení k mbid může doběhnout
později, až uživatel danou skladbu/album otevře přes normální search/browse.
"""

from __future__ import annotations

import json
from dataclasses import dataclass
from typing import Any

from sqlmodel import Session, select

from app.library.matching import attach_release_if_missing, find_or_create_artist, find_or_create_recording, find_or_create_release
from app.models import Playlist, PlaylistItem, PlaylistKind
from app.utils import utcnow

LIKED_SONGS_SOURCE = "liked-songs"
LIKED_SONGS_TITLE = "Liked Songs"


@dataclass
class ImportResult:
    total_in_file: int
    matched: int
    already_liked: int
    skipped: int


def get_or_create_liked_songs_playlist(session: Session, user_id: str) -> Playlist:
    playlist = session.exec(
        select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
    ).first()
    if playlist is None:
        playlist = Playlist(
            owner_user_id=user_id,
            title=LIKED_SONGS_TITLE,
            kind=PlaylistKind.USER,
            source=LIKED_SONGS_SOURCE,
        )
        session.add(playlist)
        session.commit()
        session.refresh(playlist)
    return playlist


def import_spotify_library(session: Session, user_id: str, raw: bytes) -> ImportResult:
    data: dict[str, Any] = json.loads(raw)
    tracks: list[dict[str, Any]] = data.get("tracks", [])

    playlist = get_or_create_liked_songs_playlist(session, user_id)
    existing_recording_ids = {
        item.recording_id
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all()
    }
    next_position = len(existing_recording_ids)

    matched = already_liked = skipped = 0
    for entry in tracks:
        artist_name = (entry.get("artist") or "").strip()
        track_name = (entry.get("track") or "").strip()
        album_name = (entry.get("album") or "").strip() or None
        if not artist_name or not track_name:
            skipped += 1
            continue

        artist = find_or_create_artist(session, artist_name)
        release = find_or_create_release(session, artist, album_name) if album_name else None
        recording = find_or_create_recording(session, artist, track_name)
        attach_release_if_missing(session, recording, release)
        matched += 1

        if recording.id in existing_recording_ids:
            already_liked += 1
            continue
        session.add(PlaylistItem(playlist_id=playlist.id, recording_id=recording.id, position=next_position))
        existing_recording_ids.add(recording.id)
        next_position += 1

    playlist.updated_at = utcnow()
    session.add(playlist)
    session.commit()

    return ImportResult(total_in_file=len(tracks), matched=matched, already_liked=already_liked, skipped=skipped)
