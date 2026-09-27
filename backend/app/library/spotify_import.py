"""Import Spotify exportů do lokální knihovny.

Podporuje dva tvary, autodetekované z obsahu (ne z přípony souboru):

  - **ZIP s CSV** (Exportify a podobné nástroje: Nastavení soukromí →
    "Stáhnout svá data", nebo export jednotlivých playlistů třetí stranou) --
    jeden CSV soubor na playlist, sloupce `Track Name`/`Artist Name(s)`/
    `Album Name`. `Liked_Songs.csv` se namapuje na speciální "Liked Songs"
    (viz `RecommendationService.daily_jams`), každý další CSV se stane
    vlastním uživatelským playlistem pojmenovaným podle souboru.
  - **`YourLibrary.json`** (oficiální Spotify GDPR export), tvar
    `{"tracks": [{"artist", "album", "track"}]}` -- vždy jde do Liked Songs.

Matchování na katalog jede přes `app.library.matching` (jméno interpreta a
název skladby, ne MusicBrainz vyhledávání) — u stovek až tisíců položek by
živé MB dotazy narazily na rate limit; přesné přiřazení k mbid může doběhnout
později, až uživatel danou skladbu/album otevře přes normální search/browse.
"""

from __future__ import annotations

import csv
import io
import json
import zipfile
from dataclasses import dataclass
from pathlib import Path
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
    already_present: int
    skipped: int
    playlists_imported: int = 1


def get_or_create_liked_songs_playlist(session: Session, user_id: str) -> Playlist:
    return _get_or_create_playlist(session, user_id, LIKED_SONGS_SOURCE, LIKED_SONGS_TITLE)


def _get_or_create_playlist(session: Session, user_id: str, source: str, title: str) -> Playlist:
    playlist = session.exec(
        select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == source)
    ).first()
    if playlist is None:
        playlist = Playlist(owner_user_id=user_id, title=title, kind=PlaylistKind.USER, source=source)
        session.add(playlist)
        session.commit()
        session.refresh(playlist)
    return playlist


def _import_tracks_into_playlist(
    session: Session, playlist: Playlist, tracks: list[tuple[str, str, str | None]]
) -> tuple[int, int, int]:
    """`tracks` je (artist_name, track_name, album_name|None). Vrací
    (matched, already_present, skipped)."""
    existing_recording_ids = {
        item.recording_id
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all()
    }
    next_position = len(existing_recording_ids)

    matched = already_present = skipped = 0
    for artist_name, track_name, album_name in tracks:
        artist_name = artist_name.strip()
        track_name = track_name.strip()
        if not artist_name or not track_name:
            skipped += 1
            continue

        artist = find_or_create_artist(session, artist_name)
        release = find_or_create_release(session, artist, album_name) if album_name else None
        recording = find_or_create_recording(session, artist, track_name)
        attach_release_if_missing(session, recording, release)
        matched += 1

        if recording.id in existing_recording_ids:
            already_present += 1
            continue
        session.add(PlaylistItem(playlist_id=playlist.id, recording_id=recording.id, position=next_position))
        existing_recording_ids.add(recording.id)
        next_position += 1

    playlist.updated_at = utcnow()
    session.add(playlist)
    session.commit()
    return matched, already_present, skipped


def _import_json(session: Session, user_id: str, raw: bytes) -> ImportResult:
    data: dict[str, Any] = json.loads(raw)
    entries = data.get("tracks", [])
    tracks = [
        (e.get("artist") or "", e.get("track") or "", (e.get("album") or "").strip() or None) for e in entries
    ]
    playlist = get_or_create_liked_songs_playlist(session, user_id)
    matched, already_present, skipped = _import_tracks_into_playlist(session, playlist, tracks)
    return ImportResult(total_in_file=len(entries), matched=matched, already_present=already_present, skipped=skipped)


def _primary_artist(field: str) -> str:
    # "Artist Name(s)" u kolaborací obsahuje víc jmen oddělených čárkou --
    # pro matchování bereme první (hlavní) interpretku/interpreta.
    return (field or "").split(",")[0].strip()


def _import_zip(session: Session, user_id: str, raw: bytes) -> ImportResult:
    total = matched = already_present = skipped = 0
    playlists_imported = 0

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        for name in zf.namelist():
            if not name.lower().endswith(".csv"):
                continue
            text = zf.read(name).decode("utf-8-sig", errors="replace")
            rows = list(csv.DictReader(io.StringIO(text)))
            total += len(rows)

            stem = Path(name).stem.strip() or "Playlist"
            if stem.replace(" ", "_").lower() == "liked_songs":
                playlist = get_or_create_liked_songs_playlist(session, user_id)
            else:
                playlist = _get_or_create_playlist(
                    session, user_id, f"spotify-import:{stem}", stem.replace("_", " ")
                )

            tracks = [
                (
                    _primary_artist(row.get("Artist Name(s)", "")),
                    (row.get("Track Name") or "").strip(),
                    (row.get("Album Name") or "").strip() or None,
                )
                for row in rows
            ]
            m, a, s = _import_tracks_into_playlist(session, playlist, tracks)
            matched += m
            already_present += a
            skipped += s
            playlists_imported += 1

    return ImportResult(
        total_in_file=total,
        matched=matched,
        already_present=already_present,
        skipped=skipped,
        playlists_imported=playlists_imported,
    )


def import_spotify_library(session: Session, user_id: str, raw: bytes) -> ImportResult:
    if raw[:2] == b"PK":  # ZIP magic bytes
        return _import_zip(session, user_id, raw)
    return _import_json(session, user_id, raw)
