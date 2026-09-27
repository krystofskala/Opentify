"""Sken lokální hudební knihovny — rekurzivně projde bind mount namapovaný
přes `MUSIC_DIR` (viz docker-compose.yml, kontejnerová cesta pevně
`/data/local-music`) a pro každý soubor:

  1. přečte ID3/Vorbis/MP4 tagy přes `mutagen`,
  2. zkusí ho napojit na MusicBrainz podle textu tagů (`CatalogService.
     match_recording_by_text`) -- na rozdíl od jména souboru/složky (které
     bývá "obcas spatne", viz zadání) MusicBrainz výsledek na místním
     pojmenování nezávisí, takže "opraví" špatně pojmenované složky/soubory
     na správný interpret/album/název, a zároveň hned dotáhne obal přes
     Deezer enrichment (`CatalogService.get_artist`/`get_release`),
  3. když se MB match nepovede (chybí tagy, nic se nenajde), spadne zpátky
     na čistě lokální name-based matching (`app.library.matching`), aby
     soubor byl aspoň přehratelný, i když bez katalogových metadat.

MusicBrainz limituje anonymní přístup na 1 request/s (`app/catalog/
musicbrainz.py`) a osobní knihovna může mít tisíce souborů -- sken proto
běží jako `asyncio` úloha na pozadí (viz `routes/library.py`), ne v rámci
jednoho HTTP requestu, a hlásí průběh přes `get_scan_progress()`.
"""

from __future__ import annotations

import logging
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from mutagen import File as MutagenFile
from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.musicbrainz import get_musicbrainz_client
from app.catalog.service import CatalogService
from app.library.matching import (
    attach_release_if_missing,
    find_or_create_artist,
    find_or_create_recording,
    find_or_create_release,
)
from app.models import MediaAsset, MediaAssetStatus, Recording
from app.utils import utcnow

logger = logging.getLogger("vault.library.scanner")

AUDIO_EXTENSIONS = {".mp3", ".flac", ".m4a", ".mp4", ".ogg", ".opus", ".wav", ".aac", ".wma"}

_TRACK_PREFIX_RE = re.compile(r"^\d+[\s._-]+")


@dataclass
class ScanProgress:
    status: str = "idle"  # idle | running | done | error
    root: str = ""
    total_files: int = 0
    scanned: int = 0
    matched_musicbrainz: int = 0
    matched_local: int = 0
    already_scanned: int = 0
    skipped_no_tags: int = 0
    errors: int = 0
    started_at: datetime | None = None
    finished_at: datetime | None = None
    error_message: str | None = None


# Jednoduchý modulový stav -- osobní nástroj, jeden sken najednou v jednom
# `api` procesu, žádná Redis/DB perzistence průběhu není potřeba.
_progress = ScanProgress()


def get_scan_progress() -> ScanProgress:
    return _progress


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


def _search_query(tags: _TrackTags, path: Path) -> str | None:
    """MusicBrainz dotaz z tagů -- a jen když ty úplně chybí, z názvu
    souboru (bez pořadového prefixu typu "01 - "), NIKDY z názvu složky,
    protože ten je podle zadání často nespolehlivý."""
    if tags.artist and tags.title:
        return f"{tags.artist} {tags.title}"
    if tags.title:
        return tags.title
    stem = _TRACK_PREFIX_RE.sub("", path.stem)
    stem = stem.replace("-", " ").replace("_", " ").strip()
    return stem or None


def _already_scanned(session: Session, path: Path) -> bool:
    return session.exec(select(MediaAsset).where(MediaAsset.storage_path == str(path))).first() is not None


def _upsert_media_asset(session: Session, recording_id: str, path: Path, source_provider: str) -> None:
    asset = session.get(MediaAsset, recording_id)
    if asset is None:
        asset = MediaAsset(recording_id=recording_id)
    # Reálný soubor na disku vyhrává nad čímkoliv dřívějším (i placeholder
    # provisioning) -- re-sken po přidání souborů do knihovny je legitimní
    # cesta, jak "opravit" dřív jen provisionable/placeholder nahrávku.
    asset.status = MediaAssetStatus.AVAILABLE
    asset.storage_path = str(path)
    asset.source_provider = source_provider
    asset.format = path.suffix.lstrip(".")
    asset.filesize_bytes = path.stat().st_size
    asset.last_error = None
    asset.updated_at = utcnow()
    session.add(asset)
    session.commit()


async def _match_locally(session: Session, tags: _TrackTags) -> Recording | None:
    if not tags.title or not tags.artist:
        return None
    artist = find_or_create_artist(session, tags.artist)
    release = find_or_create_release(session, artist, tags.album) if tags.album else None
    recording = find_or_create_recording(
        session, artist, tags.title, track_number=tags.track_number, duration_ms=tags.duration_ms
    )
    attach_release_if_missing(session, recording, release)
    return recording


async def scan_library(session: Session, root: Path) -> None:
    global _progress

    if not root.exists():
        _progress = ScanProgress(
            status="error", root=str(root), error_message="MUSIC_DIR neexistuje nebo není namountovaný"
        )
        logger.warning("MUSIC_DIR %s neexistuje -- sken přeskočen", root)
        return

    files = [p for p in sorted(root.rglob("*")) if p.is_file() and p.suffix.lower() in AUDIO_EXTENSIONS]
    _progress = ScanProgress(status="running", root=str(root), total_files=len(files), started_at=utcnow())

    catalog = CatalogService(session, get_musicbrainz_client(), get_deezer_client())

    for path in files:
        _progress.scanned += 1
        try:
            if _already_scanned(session, path):
                _progress.already_scanned += 1
                continue

            tags = _read_tags(path)
            query = _search_query(tags, path)
            recording: Recording | None = None
            source_provider = "local"

            if query:
                recording = await catalog.match_recording_by_text(query)
                if recording is not None:
                    source_provider = "musicbrainz-local"
                    if recording.artist_id:
                        await catalog.get_artist(recording.artist_id)  # dotáhne obal interpreta (Deezer)
                    if recording.release_id:
                        await catalog.get_release(recording.release_id)  # dotáhne obal alba (Deezer)

            if recording is None:
                recording = await _match_locally(session, tags)
                if recording is None:
                    _progress.skipped_no_tags += 1
                    continue

            _upsert_media_asset(session, recording.id, path, source_provider)
            if source_provider == "musicbrainz-local":
                _progress.matched_musicbrainz += 1
            else:
                _progress.matched_local += 1
        except Exception:
            logger.exception("sken selhal na souboru %s", path)
            _progress.errors += 1

    _progress.status = "done"
    _progress.finished_at = utcnow()
    logger.info(
        "sken dokončen: %s souborů, %s přes MusicBrainz, %s jen lokálně, %s přeskočeno, %s chyb",
        _progress.total_files,
        _progress.matched_musicbrainz,
        _progress.matched_local,
        _progress.skipped_no_tags,
        _progress.errors,
    )
