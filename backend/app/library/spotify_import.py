"""Import Spotify exportů do lokální knihovny.

Podporuje tvary, autodetekované z obsahu (ne z přípony souboru):

  - **ZIP s CSV** (Exportify a podobné nástroje) -- jeden CSV soubor na
    playlist, sloupce `Track Name`/`Artist Name(s)`/`Album Name`/`Duration (ms)`.
    `Liked_Songs.csv` se namapuje na speciální "Liked Songs", každý další CSV
    se stane vlastním uživatelským playlistem pojmenovaným podle souboru.
  - **Oficiální Spotify export** ("Stáhnout svá data" -> Account data) --
    ZIP nebo samostatné JSONy: `Playlist1.json`, `Playlist2.json`...
    (`{"playlists": [{"name", "items": [{"track": {"trackName",
    "artistName", "albumName"}}]}]}`) a `YourLibrary.json`
    (`{"tracks": [{"artist", "album", "track"}]}` -> Liked Songs).

Importované playlisty se **zrcadlí**: opakovaný import stejného playlistu
(klíč `Playlist.source == "spotify-import:<název>"`) nahradí jeho obsah a
pořadí podle souboru, nevzniká duplikát ani se nic nepřilepuje na konec.
Liked Songs naopak jen přibývají -- skladby oblíbené přímo v appce nesmí
reimport smazat.

Matchování na katalog jede přes `app.library.matching` (jméno interpreta a
název skladby, ne MusicBrainz vyhledávání) -- u stovek až tisíců položek by
živé MB dotazy narazily na rate limit.
"""

from __future__ import annotations

import csv
import io
import json
import re
import zipfile
from dataclasses import dataclass, field
from pathlib import PurePosixPath
from typing import Any

from sqlmodel import Session, delete, select

from app.library.matching import attach_release_if_missing, find_or_create_artist, find_or_create_recording, find_or_create_release
from app.models import MediaAsset, MediaAssetStatus, Playlist, PlaylistItem, PlaylistKind
from app.utils import utcnow

LIKED_SONGS_SOURCE = "liked-songs"
LIKED_SONGS_TITLE = "Liked Songs"
_IMPORT_SOURCE_PREFIX = "spotify-import:"

# (interpret, název skladby, album|None, délka ms|None)
TrackRow = tuple[str, str, str | None, int | None]


@dataclass
class PlaylistReport:
    playlist_id: str
    title: str
    total: int
    matched: int
    skipped: int
    in_library: int
    already_present: int


@dataclass
class ImportResult:
    playlists: list[PlaylistReport] = field(default_factory=list)

    @property
    def total_in_file(self) -> int:
        return sum(p.total for p in self.playlists)

    @property
    def matched(self) -> int:
        return sum(p.matched for p in self.playlists)

    @property
    def already_present(self) -> int:
        return sum(p.already_present for p in self.playlists)

    @property
    def skipped(self) -> int:
        return sum(p.skipped for p in self.playlists)

    @property
    def playlists_imported(self) -> int:
        return len(self.playlists)


def get_or_create_liked_songs_playlist(session: Session, user_id: str) -> Playlist:
    return _get_or_create_playlist(session, user_id, LIKED_SONGS_SOURCE, LIKED_SONGS_TITLE)


def _get_or_create_playlist(
    session: Session, user_id: str, source: str, title: str, description: str | None = None
) -> Playlist:
    playlist = session.exec(
        select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == source)
    ).first()
    if playlist is None:
        playlist = Playlist(
            owner_user_id=user_id, title=title, kind=PlaylistKind.USER, source=source, description=description
        )
        session.add(playlist)
        session.commit()
        session.refresh(playlist)
    elif playlist.title != title and source != LIKED_SONGS_SOURCE:
        playlist.title = title
        session.add(playlist)
        session.commit()
    return playlist


def _import_source_key(name: str) -> str:
    # Exportify pojmenuje soubor "Moje_oblibene.csv", oficiální export nese
    # "Moje oblibene" -- stejný klíč pro oba, ať se playlist nezdvojí, když
    # uživatel přejde z jednoho formátu na druhý.
    return _IMPORT_SOURCE_PREFIX + re.sub(r"\s+", "_", name.strip())


def _import_tracks_into_playlist(
    session: Session, playlist: Playlist, tracks: list[TrackRow], *, mirror: bool
) -> PlaylistReport:
    existing_items = session.exec(
        select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id).order_by(PlaylistItem.position)
    ).all()
    existing_ids = {item.recording_id for item in existing_items}

    matched = skipped = 0
    resolved: list[str] = []
    seen: set[str] = set()
    for artist_name, track_name, album_name, duration_ms in tracks:
        artist_name = (artist_name or "").strip()
        track_name = (track_name or "").strip()
        if not artist_name or not track_name:
            skipped += 1  # epizody podcastů, lokální soubory bez metadat
            continue
        artist = find_or_create_artist(session, artist_name)
        release = find_or_create_release(session, artist, album_name) if album_name else None
        recording = find_or_create_recording(session, artist, track_name, duration_ms=duration_ms)
        attach_release_if_missing(session, recording, release)
        matched += 1
        if recording.id not in seen:  # stejná skladba 2x v jednom playlistu -> jednou
            seen.add(recording.id)
            resolved.append(recording.id)

    already_present = sum(1 for rid in resolved if rid in existing_ids)
    if mirror:
        session.exec(delete(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id))
        final_ids = resolved
        for position, rid in enumerate(final_ids):
            session.add(PlaylistItem(playlist_id=playlist.id, recording_id=rid, position=position))
    else:
        # Oblíbené: nové NAHORU v pořadí exportu (ten je nejnovější první),
        # stejně jako lajk v appce (routes/library.like_song).
        new_ids = [rid for rid in resolved if rid not in existing_ids]
        top = min((item.position for item in existing_items), default=0)
        for i, rid in enumerate(new_ids):
            session.add(
                PlaylistItem(playlist_id=playlist.id, recording_id=rid, position=top - len(new_ids) + i)
            )
        final_ids = new_ids + [item.recording_id for item in existing_items]

    playlist.updated_at = utcnow()
    session.add(playlist)
    session.commit()

    in_library = 0
    if final_ids:
        in_library = len(
            session.exec(
                select(MediaAsset.recording_id).where(
                    MediaAsset.recording_id.in_(final_ids),  # type: ignore[union-attr]
                    MediaAsset.status == MediaAssetStatus.AVAILABLE,
                )
            ).all()
        )
    return PlaylistReport(
        playlist_id=playlist.id,
        title=playlist.title,
        total=len(tracks),
        matched=matched,
        skipped=skipped,
        in_library=in_library,
        already_present=already_present,
    )


def _import_named_playlist(
    session: Session, user_id: str, name: str, tracks: list[TrackRow], description: str = "Import ze Spotify"
) -> PlaylistReport:
    """`description` -- odkud playlist je (Spotify / YouTube Music / Apple Music)."""
    if name.replace(" ", "_").lower() == "liked_songs":
        playlist = get_or_create_liked_songs_playlist(session, user_id)
        return _import_tracks_into_playlist(session, playlist, tracks, mirror=False)
    playlist = _get_or_create_playlist(session, user_id, _import_source_key(name), name, description)
    return _import_tracks_into_playlist(session, playlist, tracks, mirror=True)


def _primary_artist(field_value: str) -> str:
    # "Artist Name(s)" u kolaborací obsahuje víc jmen oddělených čárkou --
    # pro matchování bereme první (hlavní) interpretku/interpreta.
    return (field_value or "").split(",")[0].strip()


def _int_or_none(value: Any) -> int | None:
    try:
        return int(float(value))
    except (TypeError, ValueError):
        return None


def _csv_tracks(text: str) -> list[TrackRow]:
    return [
        (
            _primary_artist(row.get("Artist Name(s)", "")),
            (row.get("Track Name") or "").strip(),
            (row.get("Album Name") or "").strip() or None,
            _int_or_none(row.get("Duration (ms)")),
        )
        for row in csv.DictReader(io.StringIO(text))
    ]


def _official_playlists(data: dict[str, Any]) -> list[tuple[str, list[TrackRow]]]:
    result = []
    for pl in data.get("playlists") or []:
        tracks: list[TrackRow] = []
        for item in pl.get("items") or []:
            track = item.get("track") or {}
            tracks.append(
                (
                    track.get("artistName") or "",
                    track.get("trackName") or "",
                    (track.get("albumName") or "").strip() or None,
                    None,
                )
            )
        result.append(((pl.get("name") or "Playlist").strip() or "Playlist", tracks))
    return result


def _library_liked(data: dict[str, Any]) -> list[TrackRow]:
    return [
        (e.get("artist") or "", e.get("track") or "", (e.get("album") or "").strip() or None, None)
        for e in data.get("tracks") or []
    ]


def _import_json_document(session: Session, user_id: str, data: dict[str, Any]) -> list[PlaylistReport]:
    reports = []
    if "playlists" in data:
        for name, tracks in _official_playlists(data):
            reports.append(_import_named_playlist(session, user_id, name, tracks))
    if "tracks" in data and isinstance(data["tracks"], list):
        playlist = get_or_create_liked_songs_playlist(session, user_id)
        reports.append(_import_tracks_into_playlist(session, playlist, _library_liked(data), mirror=False))
    return reports


def _zip_entry_name(info: zipfile.ZipInfo) -> str:
    # ZIPy z Windows/Exportify často nesou UTF-8 jména BEZ příznaku 0x800 --
    # Python je pak dekóduje jako cp437 ("Rádio" -> "R├ídio").
    if info.flag_bits & 0x800:
        return info.filename
    try:
        return info.filename.encode("cp437").decode("utf-8")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return info.filename


def _import_zip(session: Session, user_id: str, raw: bytes) -> ImportResult:
    result = ImportResult()
    from app.uploads import check_zip

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        check_zip(zf)
        for info in zf.infolist():
            if info.is_dir():
                continue
            name = _zip_entry_name(info)
            stem = PurePosixPath(name).stem.strip()
            lower = name.lower()
            if lower.endswith(".csv"):
                text = zf.read(info).decode("utf-8-sig", errors="replace")
                title = (stem or "Playlist").replace("_", " ")
                result.playlists.append(_import_named_playlist(session, user_id, title, _csv_tracks(text)))
            elif lower.endswith(".json") and (stem.lower().startswith("playlist") or stem.lower() == "yourlibrary"):
                try:
                    data = json.loads(zf.read(info).decode("utf-8-sig"))
                except json.JSONDecodeError:
                    continue
                if isinstance(data, dict):
                    result.playlists.extend(_import_json_document(session, user_id, data))
    return result


def import_spotify_library(session: Session, user_id: str, raw: bytes) -> ImportResult:
    if raw[:2] == b"PK":  # ZIP magic bytes
        return _import_zip(session, user_id, raw)
    data = json.loads(raw.decode("utf-8-sig"))
    if not isinstance(data, dict):
        raise json.JSONDecodeError("očekává se JSON objekt", "", 0)
    return ImportResult(playlists=_import_json_document(session, user_id, data))
