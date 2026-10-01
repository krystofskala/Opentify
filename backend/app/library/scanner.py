"""Sken lokální hudební knihovny — rekurzivně projde bind mount namapovaný
přes `MUSIC_DIR` (viz docker-compose.yml, kontejnerová cesta pevně
`/data/local-music`) a pro každý soubor:

  1. přečte ID3/Vorbis/MP4 tagy přes `mutagen`,
  2. soubory ve stejné složce (předpoklad: 1 složka = 1 album) zkusí napojit
     na MusicBrainz najednou podle CELÉHO tracklistu (`CatalogService.
     match_release_by_tracklist`) -- porovnání jedné skladby samotné
     (`match_recording_by_text`) je nespolehlivé pro krátké/nejednoznačné
     názvy a časté remaster varianty, což byl hlavní důvod, proč "hodně alb
     nebylo rozpoznáno". Album-level krok navíc na místním pojmenování
     nezávisí, takže "opraví" špatně pojmenované složky na správný
     interpret/album, a hned dotáhne obal přes Deezer enrichment,
  3. co album-level krok nevyřeší (singly, malé složky, žádný dost jistý
     kandidát), zkusí per-track `match_recording_by_text` stejně jako dřív,
  4. když ani to nevyjde (chybí tagy, nic se nenajde), spadne zpátky na
     čistě lokální name-based matching (`app.library.matching`), aby soubor
     byl aspoň přehratelný, i když bez katalogových metadat.

Sken je idempotentní, ale ne "jen jednou navždy": soubor, co dřív dostal jen
lokální (`local`) fallback, se při dalším skenu zkusí napojit znovu (třeba s
lepším album-level krokem, co v mezičase přibyl) -- jen soubory už úspěšně
napojené na MusicBrainz (`musicbrainz-local`) se přeskakují jako hotové.

MusicBrainz limituje anonymní přístup na 1 request/s (`app/catalog/
musicbrainz.py`) a osobní knihovna může mít tisíce souborů -- sken proto
běží jako `asyncio` úloha na pozadí (viz `routes/library.py`), ne v rámci
jednoho HTTP requestu, a hlásí průběh přes `get_scan_progress()`.
"""

from __future__ import annotations

import logging
import re
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from mutagen import File as MutagenFile
from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.musicbrainz import get_musicbrainz_client
from app.catalog.service import CatalogService, normalize_title
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

# Pod tuhle hranici souborů ve složce se album-level krok nevyplatí -- pár
# volných skladeb (singly, "Various") stačí vyřešit per-track fallbackem,
# ušetří to zbytečný MusicBrainz release-group dotaz navíc.
_MIN_ALBUM_TRACKS = 3


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


def _first(tags, *keys: str) -> str | None:
    """Vrátí první neprázdnou hodnotu z prvního klíče, co v tagách existuje --
    `easy=True` dává jednotné `title`/`artist`/`album`/`tracknumber` klíče jen
    pro ID3/FLAC/Ogg/MP4. `.wma` (ASF) žádnou "easy" variantu nemá vůbec --
    `MutagenFile(path, easy=True)` u něj tiše vrátí syrový `ASF` objekt se
    svými vlastními klíči (`Author`, `WM/AlbumTitle`, `Title`, `WM/TrackNumber`),
    takže bez těchhle záložních klíčů vychází pro každý .wma soubor artist i
    album jako `None` -- `_search_query`/`_match_folder_by_album` pak nemají
    žádný kontext a matchnou skladbu podle holého (často nejednoznačného)
    názvu na cokoliv, co MB vrátí jako první výsledek."""
    for key in keys:
        values = tags.get(key)
        if values:
            return str(values[0])
    return None


def _read_tags(path: Path) -> _TrackTags:
    audio = MutagenFile(path, easy=True)
    if audio is None:
        return _TrackTags(None, None, None, None, None)

    track_number = None
    raw_track = _first(audio, "tracknumber", "WM/TrackNumber")
    if raw_track:
        try:
            track_number = int(raw_track.split("/")[0])
        except ValueError:
            track_number = None  # neočíslovaný/neparsovatelný tag, ne chyba

    duration_ms = None
    info = getattr(audio, "info", None)
    if info is not None and getattr(info, "length", None):
        duration_ms = int(info.length * 1000)

    # Štítky zapsané v cp1250 a přečtené jako latin1 ("Pelí\x9aky", "Zemì")
    # -- stejná oprava jako při přestavbě vlastní hudby.
    from app.tools.rebuild_own_library import fix_text

    def tag(*keys: str) -> str | None:
        return fix_text(_first(audio, *keys), str(path))

    return _TrackTags(
        title=tag("title", "Title"),
        artist=tag("artist", "Author", "WM/AlbumArtist"),
        album=tag("album", "WM/AlbumTitle"),
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


def _majority_value(values: list[str | None]) -> str | None:
    """Nejčastější neprázdná hodnota mezi tagy souborů ve složce -- řeší pár
    špatně otagovaných souborů uprostřed jinak konzistentní složky (typicky
    jeden soubor s prázdným/jiným album tagem)."""
    counter = Counter(v.strip() for v in values if v and v.strip())
    if not counter:
        return None
    return counter.most_common(1)[0][0]


def _existing_asset(session: Session, path: Path) -> MediaAsset | None:
    return session.exec(select(MediaAsset).where(MediaAsset.storage_path == str(path))).first()


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


def _reassign_media_asset(
    session: Session, existing: MediaAsset | None, recording_id: str, path: Path, source_provider: str
) -> None:
    """Když soubor dřív dostal jiný (typicky lokálně založený, špatný)
    `recording_id` a teď se přemapovává na skutečnou MusicBrainz nahrávku,
    stará `MediaAsset` řádka by jinak zůstala jako duplicitní "phantom"
    záznam ukazující na stejný soubor pod jiným ID -- smaže se, aby v
    knihovně nebyla stejná skladba dvakrát."""
    if existing is not None and existing.recording_id != recording_id:
        session.delete(existing)
        session.commit()
    _upsert_media_asset(session, recording_id, path, source_provider)


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


async def _match_folder_by_album(
    session: Session,
    catalog: CatalogService,
    folder: Path,
    tags_by_path: dict[Path, _TrackTags],
    existing_by_path: dict[Path, MediaAsset | None],
) -> set[Path]:
    """Zkusí napojit celou složku na jedno MusicBrainz album najednou. Vrátí
    množinu souborů, které se podařilo přiřadit ke konkrétní skladbě
    matchnutého alba -- zbytek (album se nenašel, nebo konkrétní soubor v
    tracklistu nemá jasný protějšek) padá na per-track fallback v
    `scan_library`."""
    artist_hint = _majority_value([t.artist for t in tags_by_path.values()])
    album_hint = _majority_value([t.album for t in tags_by_path.values()])
    if not album_hint:
        return set()

    local_titles = [tags.title or path.stem for path, tags in tags_by_path.items()]
    try:
        match = await catalog.match_release_by_tracklist(artist_hint, album_hint, local_titles)
    except Exception:
        logger.exception("album match selhal pro složku %s", folder)
        return set()
    if match is None:
        return set()

    release, recordings = match
    if release.artist_id:
        await catalog.get_artist(release.artist_id)  # obal interpreta (Deezer)
    await catalog.get_release(release.id)  # obal alba (Deezer)

    by_title = {normalize_title(r.title): r for r in recordings}
    by_track_number = {r.track_number: r for r in recordings if r.track_number is not None}

    matched: set[Path] = set()
    for path, tags in tags_by_path.items():
        local_title = tags.title or path.stem
        recording = by_title.get(normalize_title(local_title))
        if recording is None and tags.track_number is not None:
            recording = by_track_number.get(tags.track_number)
        if recording is None:
            continue  # tenhle konkrétní soubor se do jinak matchnutého alba nenapasoval
        _reassign_media_asset(session, existing_by_path.get(path), recording.id, path, "musicbrainz-local")
        matched.add(path)

    return matched


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

    # 1) Načti existující stav + tagy. Soubory už napojené na MusicBrainz
    #    (`musicbrainz-local`) se dál nedotýkají -- jen nové soubory a
    #    dřívější `local` fallbacky jsou kandidáti na (re)match.
    existing_by_path: dict[Path, MediaAsset | None] = {}
    tags_by_path: dict[Path, _TrackTags] = {}
    folders: dict[Path, list[Path]] = defaultdict(list)
    for path in files:
        existing = _existing_asset(session, path)
        existing_by_path[path] = existing
        if existing is not None and existing.source_provider == "musicbrainz-local":
            continue
        try:
            tags_by_path[path] = _read_tags(path)
        except Exception:
            # Poškozený/nestandardní soubor (mutagen umí spadnout na "can't
            # sync to MPEG frame" apod.) -- dřívější verze tohle odchytávala
            # per-soubor v hlavní smyčce; tenhle krok běží PŘED ní, takže bez
            # vlastního try/except by jedna vadná MP3ka shodila celý sken
            # (přesně tenhle bug nechal `_progress.status` navěky na
            # "running", protože výjimka zabila celý asyncio task).
            logger.exception("čtení tagů selhalo pro %s", path)
            _progress.errors += 1
            continue
        folders[path.parent].append(path)

    # 2) Album-level pokus po složkách -- viz `_match_folder_by_album`.
    processed: set[Path] = set()
    for folder, paths in folders.items():
        if len(paths) < _MIN_ALBUM_TRACKS:
            continue
        folder_tags = {p: tags_by_path[p] for p in paths}
        matched = await _match_folder_by_album(session, catalog, folder, folder_tags, existing_by_path)
        processed |= matched
        _progress.matched_musicbrainz += len(matched)

    # 3) Fallback: per-track MusicBrainz + čistě lokální, pro cokoliv, co
    #    krok 2 nevyřešil (singly, malé složky, nejistý/žádný album match).
    for path in files:
        _progress.scanned += 1
        if path in processed:
            continue
        try:
            existing = existing_by_path.get(path)
            if existing is not None and existing.source_provider == "musicbrainz-local":
                _progress.already_scanned += 1
                continue

            tags = tags_by_path.get(path) or _read_tags(path)
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

            _reassign_media_asset(session, existing, recording.id, path, source_provider)
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
