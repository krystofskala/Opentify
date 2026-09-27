"""Sken lokální hudební knihovny — rekurzivně projde bind mount namapovaný
přes `MUSIC_DIR` (viz docker-compose.yml, kontejnerová cesta pevně
`/data/local-music`), přečte ID3/Vorbis/MP4 tagy přes `mutagen` a zaeviduje
nalezené soubory jako `MediaAsset.status = AVAILABLE` — bez provisioningu,
protože soubor už fyzicky leží na disku.

Matchování na Artist/Release/Recording jede přes `app.library.matching`
(jméno/název, ne MusicBrainz) — cílem skenu je *zpřístupnit soubory, které
uživatel už má*, ne obohatit katalog o MusicBrainz metadata (to dělá
CatalogService při search/browse).
"""

from __future__ import annotations

import logging
from dataclasses import dataclass
from pathlib import Path

from mutagen import File as MutagenFile
from sqlmodel import Session

from app.library.matching import (
    attach_release_if_missing,
    find_or_create_artist,
    find_or_create_recording,
    find_or_create_release,
)
from app.models import MediaAsset, MediaAssetStatus
from app.utils import utcnow

logger = logging.getLogger("vault.library.scanner")

AUDIO_EXTENSIONS = {".mp3", ".flac", ".m4a", ".mp4", ".ogg", ".opus", ".wav", ".aac", ".wma"}


@dataclass
class ScanResult:
    scanned: int
    matched: int
    skipped_no_tags: int
    errors: int


@dataclass
class _TrackTags:
    title: str | None
    artist: str | None
    album: str | None
    track_number: int | None
    duration_ms: int | None


def _first(tags, key: str) -> str | None:
    values = tags.get(key)
    return str(values[0]) if values else None


def _read_tags(path: Path) -> _TrackTags:
    audio = MutagenFile(path, easy=True)
    if audio is None:
        return _TrackTags(None, None, None, None, None)

    track_number = None
    raw_track = _first(audio, "tracknumber")
    if raw_track:
        try:
            track_number = int(raw_track.split("/")[0])
        except ValueError:
            track_number = None  # neočíslovaný/neparsovatelný tag, ne chyba

    duration_ms = None
    info = getattr(audio, "info", None)
    if info is not None and getattr(info, "length", None):
        duration_ms = int(info.length * 1000)

    return _TrackTags(
        title=_first(audio, "title"),
        artist=_first(audio, "artist"),
        album=_first(audio, "album"),
        track_number=track_number,
        duration_ms=duration_ms,
    )


def _upsert_local_media_asset(session: Session, recording_id: str, path: Path) -> None:
    asset = session.get(MediaAsset, recording_id)
    if asset is None:
        asset = MediaAsset(recording_id=recording_id)
    # Reálný soubor na disku vyhrává nad čímkoliv dřívějším (i placeholder
    # provisioning) -- re-sken po přidání souborů do knihovny je legitimní
    # cesta, jak "opravit" dřív jen provisionable/placeholder nahrávku.
    asset.status = MediaAssetStatus.AVAILABLE
    asset.storage_path = str(path)
    asset.source_provider = "local"
    asset.format = path.suffix.lstrip(".")
    asset.filesize_bytes = path.stat().st_size
    asset.last_error = None
    asset.updated_at = utcnow()
    session.add(asset)
    session.commit()


def scan_library(session: Session, root: Path) -> ScanResult:
    if not root.exists():
        logger.warning("MUSIC_DIR %s neexistuje (nenamapovaný bind mount?) -- sken přeskočen", root)
        return ScanResult(scanned=0, matched=0, skipped_no_tags=0, errors=0)

    scanned = matched = skipped = errors = 0
    for path in sorted(root.rglob("*")):
        if not path.is_file() or path.suffix.lower() not in AUDIO_EXTENSIONS:
            continue
        scanned += 1
        try:
            tags = _read_tags(path)
            if not tags.title or not tags.artist:
                skipped += 1
                continue

            artist = find_or_create_artist(session, tags.artist)
            release = find_or_create_release(session, artist, tags.album) if tags.album else None
            recording = find_or_create_recording(
                session, artist, tags.title, track_number=tags.track_number, duration_ms=tags.duration_ms
            )
            attach_release_if_missing(session, recording, release)
            _upsert_local_media_asset(session, recording.id, path)
            matched += 1
        except Exception:
            logger.exception("sken selhal na souboru %s", path)
            errors += 1

    return ScanResult(scanned=scanned, matched=matched, skipped_no_tags=skipped, errors=errors)
