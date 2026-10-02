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
import re
import unicodedata
import zipfile
from contextvars import ContextVar
from pathlib import Path

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, Request, UploadFile
from pydantic import BaseModel
from sqlalchemy import and_, func, or_
from sqlmodel import Session, select

from app.auth import ADMIN_ID, get_current_user, require_admin
from app.utils import utcnow
from app.catalog.availability import compute_availability, resolve_artist_name
from app.catalog.schemas import Availability, CamelModel, RecordingOut
from app.db import engine, get_session
from app.library.scanner import ScanProgress, get_scan_progress, scan_library
from app.library.entries import add_to_library
from app.library.entries import remove_from_library as remove_entry
from app.library.dislikes import disliked_ids, purge_from_snapshots, send_feedback_later
from app.library.spotify_link import SpotifyLinkError, import_spotify_link
from app.library.spotify_import import (
    LIKED_SONGS_SOURCE,
    LIKED_SONGS_TITLE,
    get_or_create_liked_songs_playlist,
    import_spotify_library,
)
from app.models import (
    Artist,
    AppUser,
    CollectionProgress,
    LibraryEntry,
    ProvisioningJob,
    MediaAsset,
    MediaAssetStatus,
    Playlist,
    PlaylistItem,
    PlaylistKind,
    Recording,
    RecordingDislike,
    Release,
)

# Admin: přepínač v Knihovně "Vše na serveru" (hlavička X-Library-Scope: all)
# -- celá sdílená knihovna místo klasické. Async závislost, ať hodnota
# doputuje i do synchronních endpointů (threadpool kopíruje kontext).
_scope: ContextVar[str] = ContextVar("library_scope", default="mine")


async def _library_scope(request: Request) -> None:
    # "mine" (klasická knihovna) | "downloaded" (co si profil stáhl) |
    # "all" (celý server, jen admin)
    _scope.set(request.headers.get("x-library-scope") or "mine")


def _downloaded_by(user_id: str):
    """Co si profil stáhl/pustil. Admin: všechno stažené kromě skladeb, které
    stáhl jen jiný profil (starší stažení nemají záznam úlohy), plus jeho
    hudba z PC."""
    if user_id == ADMIN_ID:
        foreign_only = (
            select(ProvisioningJob.recording_id)
            # Jen skutečné profily -- staré testovací úlohy ("bench...") jsou adminovy.
            .where(
                ProvisioningJob.requested_by_user_id.in_(  # type: ignore[attr-defined]
                    select(AppUser.id).where(AppUser.id != ADMIN_ID)
                )
            )
            .where(
                ProvisioningJob.recording_id.not_in(  # type: ignore[attr-defined]
                    select(ProvisioningJob.recording_id).where(ProvisioningJob.requested_by_user_id == ADMIN_ID)
                )
            )
        )
        return and_(_IN_LIBRARY, MediaAsset.recording_id.not_in(foreign_only))  # type: ignore[attr-defined]
    mine = select(ProvisioningJob.recording_id).where(ProvisioningJob.requested_by_user_id == user_id)
    return and_(_IN_LIBRARY, MediaAsset.recording_id.in_(mine))  # type: ignore[attr-defined]


library_router = APIRouter(prefix="/library", tags=["library"], dependencies=[Depends(_library_scope)])

# Kontejnerová cesta je pevná (bind mount cíl v docker-compose.yml) -- co se
# mění mezi Windows vývojem a Linux serverem, je jen `MUSIC_DIR` (hostitelská
# strana mountu), kód se nedotkne.
LOCAL_MUSIC_ROOT = Path(os.environ.get("LOCAL_MUSIC_ROOT", "/data/local-music"))

# Jen soubory pod tímhle kořenem appka sama stáhla a smí je smazat
# ("Odebrat z knihovny"); cokoliv jinde (uživatelova složka, slskd sdílená
# složka připojená jen pro čtení) se jen skryje.
MEDIA_ROOT = Path(os.environ.get("MEDIA_ROOT", "/data/media"))

# "Je v knihovně" = přehratelné na disku A uživatel ho neodebral.
_IN_LIBRARY = and_(
    MediaAsset.status == MediaAssetStatus.AVAILABLE,
    or_(MediaAsset.hidden_from_library.is_(None), MediaAsset.hidden_from_library.is_(False)),  # type: ignore[union-attr]
)


def _in_library(user_id: str):
    """Klasická knihovna (jako Spotify/Apple Music): jen co si profil sám
    přidal -- tlačítkem "Přidat do knihovny" (`LibraryEntry`), lajkem
    (Oblíbené), a u admina navíc jeho vlastní hudba z PC. Poslech ani
    stažení skladbu do knihovny nepřidá. Soubory jsou sdílené mezi profily
    (co má stažené jeden, hraje druhému hned), knihovna ne."""
    liked = (
        select(PlaylistItem.recording_id)
        .join(Playlist, Playlist.id == PlaylistItem.playlist_id)
        .where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
    )
    entries = select(LibraryEntry.recording_id).where(LibraryEntry.user_id == user_id)
    mine = or_(
        MediaAsset.recording_id.in_(entries),  # type: ignore[attr-defined]
        MediaAsset.recording_id.in_(liked),  # type: ignore[attr-defined]
    )
    scope = _scope.get()
    if scope == "all" and user_id == ADMIN_ID:
        return _IN_LIBRARY
    if scope == "downloaded":
        return _downloaded_by(user_id)
    if user_id == ADMIN_ID:
        own_music = MediaAsset.source_provider.in_(("local", "musicbrainz-local"))  # type: ignore[union-attr]
        mine = or_(mine, own_music)
    return and_(_IN_LIBRARY, mine)


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
async def scan(_current: tuple[str, str] = Depends(require_admin)):
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
    current: tuple[str, str] = Depends(get_current_user),
):
    """"Moje knihovna" -- cokoliv `AVAILABLE` na disku, ať už z lokálního
    skenu (`POST /library/scan`), nebo dřív obstarané přes
    `POST /tracks/{id}/provision` (slskd/YouTube). Dřív filtrovalo jen podle
    `source_provider in (local, musicbrainz-local)`, takže stažené/obstarané
    skladby v knihovně nikdy neskončily, i když je appka měla reálně na
    disku a šly rovnou přehrát -- odsud "proč to nemám v knihovně"."""
    total = session.exec(select(func.count()).select_from(MediaAsset).where(_in_library(current[0]))).one()
    # Jeden dotaz (asset + nahrávka + interpret) místo tří na každý řádek.
    rows = session.exec(
        select(Recording, Artist.name)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .outerjoin(Artist, Artist.id == Recording.artist_id)
        .where(_in_library(current[0]))
        .order_by(MediaAsset.updated_at.desc())
        .offset(offset)
        .limit(limit)
    ).all()

    items = [
        RecordingOut(
            id=recording.id,
            mbid=recording.mbid,
            release_id=recording.release_id,
            artist_id=recording.artist_id,
            artist_name=artist_name,
            title=recording.title,
            duration_ms=recording.duration_ms,
            isrc=recording.isrc,
            track_number=recording.track_number,
            # Filtr `_in_library(current[0])` = soubor je na disku a přehratelný.
            availability=Availability.AVAILABLE,
            preview_url=recording.external_refs.get("previewUrl"),
        )
        for recording, artist_name in rows
    ]

    return {"total": total, "items": [i.model_dump(by_alias=True) for i in items]}


@library_router.get("/local-albums")
def local_albums(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
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
            func.max(func.coalesce(LibraryEntry.added_at, MediaAsset.updated_at)),
            Release.external_refs,
        )
        .join(Recording, Recording.release_id == Release.id)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .join(Artist, Artist.id == Release.artist_id)
        .outerjoin(
            LibraryEntry,
            (LibraryEntry.recording_id == Recording.id) & (LibraryEntry.user_id == current[0]),  # type: ignore[arg-type]
        )
        .where(_in_library(current[0]))
        .group_by(Release.id)
        .order_by(Artist.name, Release.title)
    ).all()

    # Různé názvy skladeb alba v knihovně (katalog má občas stejnou skladbu
    # dvakrát) -- pro "celé album".
    owned_titles: dict[str, set[str]] = {}
    for release_id, rec_title in session.exec(
        select(Recording.release_id, Recording.title)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .outerjoin(
            LibraryEntry,
            (LibraryEntry.recording_id == Recording.id) & (LibraryEntry.user_id == current[0]),  # type: ignore[arg-type]
        )
        .where(_in_library(current[0]))
    ).all():
        owned_titles.setdefault(release_id, set()).add((rec_title or "").strip().lower())

    out = []
    for release_id, title, images, artist_id, artist_name, track_count, added_at, refs in rows:
        total = (refs or {}).get("tracklistCount")
        out.append(
            {
                "id": release_id,
                "title": title,
                "coverImageUrl": images[0] if images else None,
                "artistId": artist_id,
                "artistName": artist_name,
                "trackCount": track_count,
                # Kdy přibyla do knihovny (nejnovější skladba) -- řazení "Přidáno".
                "addedAt": _iso(added_at),
                # Celé album: všechny skladby tracklistu v knihovně (tracklist
                # neznámý = nevíme, do filtru "Jen celá alba" nepatří).
                "totalTracks": total,
                "complete": bool(total) and len(owned_titles.get(release_id, ())) >= total,
            }
        )
    return out


def _iso(value) -> str | None:  # noqa: ANN001 -- SQLite vrací str nebo datetime
    if value is None:
        return None
    return value if isinstance(value, str) else value.isoformat()


@library_router.get("/local-artists")
def local_artists(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Interpreti seskupení z lokální knihovny -- viz `local_albums`, stejný
    princip (jeden GROUP BY dotaz, ne N+1 z klienta)."""
    rows = session.exec(
        select(
            Artist.id,
            Artist.name,
            Artist.images,
            func.count(func.distinct(Recording.id)),
            func.max(func.coalesce(LibraryEntry.added_at, MediaAsset.updated_at)),
        )
        .join(Recording, Recording.artist_id == Artist.id)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .outerjoin(
            LibraryEntry,
            (LibraryEntry.recording_id == Recording.id) & (LibraryEntry.user_id == current[0]),  # type: ignore[arg-type]
        )
        .where(_in_library(current[0]))
        .group_by(Artist.id)
        .order_by(Artist.name)
    ).all()

    return [
        {
            "id": artist_id,
            "name": name,
            "imageUrl": images[0] if images else None,
            "trackCount": track_count,
            "addedAt": _iso(added_at),
        }
        for artist_id, name, images, track_count, added_at in rows
    ]


def _fold(text: str | None) -> str:
    """Bez diakritiky, malá písmena, jen alfanumerické tokeny oddělené
    mezerou -- "Vypsaná fiXa" i "vypsana fixa" dají stejný řetězec."""
    folded = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().casefold()
    return " ".join(re.findall(r"[a-z0-9]+", folded))


def _match_score(query_tokens: list[str], *fields: str | None) -> int:
    """0 = neodpovídá. Všechny tokeny dotazu musí být někde v polích;
    shoda od začátku slova/celého pole se řadí výš než shoda uprostřed."""
    haystack = " ".join(_fold(f) for f in fields if f)
    if not all(token in haystack for token in query_tokens):
        return 0
    primary = _fold(fields[0])
    joined = " ".join(query_tokens)
    if primary == joined:
        return 4
    if primary.startswith(joined):
        return 3
    if all(re.search(rf"(^| ){re.escape(t)}", haystack) for t in query_tokens):
        return 2
    return 1


@library_router.get("/search")
def search_library(
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(default=20, ge=1, le=100),
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Hledání jen v tom, co je v knihovně (přehratelné skladby, jejich alba
    a interpreti, vlastní playlisty) -- bez diakritiky a velikosti písmen.
    Normalizace v Pythonu, ne SQL `LIKE`: SQLite neumí porovnání bez
    diakritiky a knihovna má řádově tisíce skladeb, takže průchod v paměti
    je rychlejší než cokoli, co by se muselo složitě indexovat."""
    user_id, _device_id = current
    tokens = _fold(q).split()
    if not tokens:
        return {"query": q, "tracks": [], "albums": [], "artists": [], "playlists": []}

    rows = session.exec(
        select(Recording, Artist.name, Release.title)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .join(Artist, Artist.id == Recording.artist_id, isouter=True)
        .join(Release, Release.id == Recording.release_id, isouter=True)
        .where(_in_library(current[0]))
    ).all()
    # Skóre bere lepší z "název je hlavní pole" a "interpret je hlavní pole"
    # -- dotaz "radiohead" jinak řadil skladbu *pojmenovanou* "Radiohead" od
    # jiného interpreta nad skladby Radiohead.
    def track_score(rec: Recording, artist_name: str | None, album_title: str | None) -> tuple[int, int]:
        by_title = _match_score(tokens, rec.title, artist_name, album_title)
        by_artist = _match_score(tokens, artist_name, rec.title, album_title)
        return max(by_title, by_artist), by_artist

    scored_tracks = sorted(
        ((score, rec) for rec, artist_name, album_title in rows
         if (score := track_score(rec, artist_name, album_title))[0]),
        key=lambda pair: (-pair[0][0], -pair[0][1], pair[1].title.casefold()),
    )[:limit]

    albums = [a for a in local_albums(session=session, _current=current) if _match_score(tokens, a["title"], a["artistName"])]
    albums.sort(key=lambda a: (-_match_score(tokens, a["title"], a["artistName"]), a["title"].casefold()))
    artists = [a for a in local_artists(session=session, _current=current) if _match_score(tokens, a["name"])]
    artists.sort(key=lambda a: (-_match_score(tokens, a["name"]), -a["trackCount"]))

    playlists = session.exec(
        select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.kind == PlaylistKind.USER)
    ).all()
    playlist_hits = []
    for p in playlists:
        if p.source == LIKED_SONGS_SOURCE or not _match_score(tokens, p.title):
            continue
        count = session.exec(
            select(func.count()).select_from(PlaylistItem).where(PlaylistItem.playlist_id == p.id)
        ).one()
        playlist_hits.append({"id": p.id, "title": p.title, "kind": p.kind, "source": p.source, "itemCount": count})
    playlist_hits.sort(key=lambda p: (-_match_score(tokens, p["title"]), p["title"].casefold()))

    return {
        "query": q,
        "tracks": [_local_recording_out(session, rec).model_dump(by_alias=True) for _score, rec in scored_tracks],
        "albums": albums[:limit],
        "artists": artists[:limit],
        "playlists": playlist_hits[:limit],
    }


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
    current: tuple[str, str] = Depends(get_current_user),
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
        .where(_in_library(current[0]))
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
    current: tuple[str, str] = Depends(get_current_user),
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
            _in_library(current[0]),
            Recording.release_id.in_(matching_release_ids),
        )
    ).all()
    items = [_local_recording_out(session, r) for r in recordings]
    return {"total": len(items), "items": [i.model_dump(by_alias=True) for i in items]}


@library_router.get("/czech")
def local_czech(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Skladby interpretů s MusicBrainz `country == "CZ"` (viz
    `CatalogService._enrich_artist_country`, líné doplnění při otevření
    interpreta) -- pohání "Česká hudba" na Home."""
    recordings = session.exec(
        select(Recording)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .join(Artist, Artist.id == Recording.artist_id)
        .where(_in_library(current[0]), Artist.country == "CZ")
    ).all()
    items = [_local_recording_out(session, r) for r in recordings]
    return {"total": len(items), "items": [i.model_dump(by_alias=True) for i in items]}


class RemoveTracksBody(CamelModel):
    recording_ids: list[str]


def _remove_from_library(session: Session, recording_id: str, dry_run: bool = False) -> dict:
    """Stažený soubor (pod MEDIA_ROOT) se smaže a skladba se vrátí do stavu
    "nestaženo" -- při dalším přehrání se prostě stáhne znovu. Soubor mimo
    MEDIA_ROOT (uživatelova hudební složka, jen pro čtení) se nemaže, jen
    skryje z knihovny."""
    asset = session.get(MediaAsset, recording_id)
    if asset is None or asset.status != MediaAssetStatus.AVAILABLE or asset.hidden_from_library:
        return {"recordingId": recording_id, "result": "not_in_library", "freedBytes": 0}

    path = Path(asset.storage_path) if asset.storage_path else None
    owned = path is not None and path.resolve().is_relative_to(MEDIA_ROOT.resolve())
    if dry_run:
        size = 0
        if owned:
            try:
                size = path.stat().st_size
            except FileNotFoundError:
                size = 0
        return {"recordingId": recording_id, "result": "deleted" if owned else "hidden", "freedBytes": size}
    if not owned:
        asset.hidden_from_library = True
        session.add(asset)
        session.commit()
        return {"recordingId": recording_id, "result": "hidden", "freedBytes": 0}

    freed = 0
    try:
        freed = path.stat().st_size
        path.unlink()
    except FileNotFoundError:
        pass
    asset.status = MediaAssetStatus.MISSING
    asset.storage_path = None
    asset.filesize_bytes = None
    asset.checksum_sha256 = None
    asset.loudness_gain_db = None
    asset.waveform = None
    asset.waveform_duration_ms = None
    asset.hidden_from_library = None
    session.add(asset)
    session.commit()
    return {"recordingId": recording_id, "result": "deleted", "freedBytes": freed}


def _remove_for(session: Session, user_id: str, recording_id: str, dry_run: bool = False) -> dict:
    """Odebrat z knihovny profilu. Soubor se smaže (uvolní místo) jen
    u admina a jen když ho v knihovně nemá nikdo jiný; jinak zůstává
    sdílený pro rychlé přehrání."""
    if not dry_run:
        remove_entry(session, user_id, recording_id)
    others = session.exec(
        select(LibraryEntry).where(LibraryEntry.recording_id == recording_id, LibraryEntry.user_id != user_id)
    ).first()
    if user_id == ADMIN_ID and others is None:
        return _remove_from_library(session, recording_id, dry_run)
    return {"recordingId": recording_id, "result": "hidden", "freedBytes": 0}


@library_router.get("/heard")
def heard_fully(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Id skladeb, které profil aspoň jednou poslechl celé: zapsané z appky
    (`POST /library/heard/{id}`) + poslechy z historie (import ze Spotify),
    kde odehraný čas pokryl aspoň 90 % délky skladby."""
    from app.models import HeardFully, Listen

    user_id = current[0]
    ids = set(session.exec(select(HeardFully.recording_id).where(HeardFully.user_id == user_id)).all())
    ids |= set(
        session.exec(
            select(Listen.recording_id)
            .join(Recording, Recording.id == Listen.recording_id)
            .where(
                Listen.user_id == user_id,
                Listen.duration_played_ms.is_not(None),  # type: ignore[union-attr]
                Recording.duration_ms.is_not(None),  # type: ignore[union-attr]
                Listen.duration_played_ms >= Recording.duration_ms * 0.9,  # type: ignore[operator]
            )
            .distinct()
        ).all()
    )
    return {"recordingIds": sorted(ids)}


@library_router.post("/heard/{recording_id}")
def mark_heard_fully(
    recording_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    from app.models import HeardFully

    if session.get(Recording, recording_id) is None:
        raise HTTPException(status_code=404, detail="skladba nenalezena")
    if session.get(HeardFully, (current[0], recording_id)) is None:
        session.add(HeardFully(user_id=current[0], recording_id=recording_id))
        session.commit()
    return {"recordingId": recording_id, "heard": True}


@library_router.get("/entries")
def library_entries(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Id skladeb v knihovně profilu (pro "Přidat/Odebrat z knihovny")."""
    # Vždy klasická knihovna, bez ohledu na přepínač pohledu v Knihovně.
    token = _scope.set("mine")
    try:
        ids = session.exec(select(MediaAsset.recording_id).where(_in_library(current[0]))).all()
    finally:
        _scope.reset(token)
    return {"recordingIds": sorted(set(ids))}


async def _add_and_fetch(user_id: str, device_id: str, recording_ids: list[str]) -> int:
    """Přidat do knihovny + stáhnout, co ještě staženo není (knihovna =
    přehratelné hned)."""
    from app.provisioning_service import enqueue, get_or_create_job

    added = 0
    with Session(engine) as session:
        for rid in recording_ids:
            if session.get(Recording, rid) is None:
                continue
            add_to_library(session, user_id, rid)
            added += 1
            try:
                _asset, job, created = get_or_create_job(session, rid, user_id, device_id)
            except LookupError:
                continue
            if job is not None and created:
                await enqueue(job)
    return added


@library_router.post("/tracks/{recording_id}")
async def add_track(recording_id: str, current: tuple[str, str] = Depends(get_current_user)):
    """"Přidat do knihovny" -- skladba."""
    added = await _add_and_fetch(current[0], current[1], [recording_id])
    if not added:
        raise HTTPException(status_code=404, detail="skladba nenalezena")
    return {"recordingId": recording_id, "inLibrary": True}


@library_router.post("/albums/{release_id}")
async def add_album(
    release_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """"Přidat do knihovny" -- celé album (skladby, které katalog zná)."""
    ids = list(session.exec(select(Recording.id).where(Recording.release_id == release_id)).all())
    if not ids:
        raise HTTPException(status_code=404, detail="album nemá skladby v katalogu")
    added = await _add_and_fetch(current[0], current[1], ids)
    return {"releaseId": release_id, "added": added}


@library_router.delete("/tracks/{recording_id}")
def remove_track(
    recording_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """"Odebrat z knihovny" -- neodebírá z Oblíbených ani z playlistů (to
    jsou samostatné akce), jen z "Moje knihovna". Jiný profil než admin
    maže jen svou položku, sdílený soubor zůstává."""
    return _remove_for(session, current[0], recording_id)


@library_router.post("/tracks/remove")
def remove_tracks(
    body: RemoveTracksBody,
    dry_run: bool = Query(default=False, alias="dryRun"),
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """`?dryRun=true` -- jen spočítá, co by se stalo (kolik MB se uvolní, co
    se jen skryje), pro potvrzovací sheet v klientovi. Nic nemění."""
    results = [_remove_for(session, current[0], rid, dry_run) for rid in body.recording_ids[:500]]
    return {
        "removed": sum(1 for r in results if r["result"] != "not_in_library"),
        "freedBytes": sum(r["freedBytes"] for r in results),
        "results": results,
    }


@library_router.post("/import/spotify")
async def import_spotify(
    file: UploadFile,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    from app.uploads import read_limited

    user_id, _device_id = current
    raw = await read_limited(file, 300 * 1024 * 1024, "Export")
    # ZIP s historií poslechů (Extended streaming history) -> poslechy
    # profilu, za který se jedná (Wrapped, mixy); jinak playlisty/knihovna.
    try:
        from app.library.spotify_history import import_history, read_zip

        plays = read_zip(raw)
    except (zipfile.BadZipFile, ValueError, KeyError):
        plays = []
    if plays:
        from app.home import generators as g

        token = g.set_home_user(user_id)
        try:
            result = await asyncio.to_thread(import_history, user_id, plays)
        finally:
            g.reset_home_user(token)
        return {"kind": "history", **{k: v for k, v in result.items() if isinstance(v, (int, str, float, bool))}}
    try:
        # Stovky skladeb do DB -- mimo event loop, ať mezitím hraje hudba.
        def run():
            with Session(engine) as own:
                return import_spotify_library(own, user_id, raw)

        result = await asyncio.to_thread(run)
    except (json.JSONDecodeError, zipfile.BadZipFile) as exc:
        raise HTTPException(
            status_code=400,
            detail="Nepodařilo se rozpoznat formát -- očekává se Spotify export (ZIP, Playlist1.json nebo YourLibrary.json).",
        ) from exc
    return {
        "totalInFile": result.total_in_file,
        "matched": result.matched,
        "alreadyPresent": result.already_present,
        "skipped": result.skipped,
        "playlistsImported": result.playlists_imported,
        "playlists": [
            {
                "id": p.playlist_id,
                "title": p.title,
                "total": p.total,
                "matched": p.matched,
                "skipped": p.skipped,
                "inLibrary": p.in_library,
            }
            for p in result.playlists
        ],
    }


class SpotifyLinkIn(BaseModel):
    url: str


@library_router.post("/import/spotify-link")
async def import_spotify_link_route(
    body: SpotifyLinkIn,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Odkaz na Spotify playlist/album/skladbu -> playlist v knihovně (viz
    `app/library/spotify_link.py`). Volá ho vyhledávání v appce i zkratka
    iOS "Do Opentify" ze sdílení (bez hlaviček -> výchozí uživatel)."""
    user_id, _device_id = current
    try:
        result = await import_spotify_link(session, user_id, body.url)
    except SpotifyLinkError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    except httpx.HTTPError as exc:
        raise HTTPException(status_code=502, detail="Odkaz se nepodařilo načíst, zkus to za chvíli.") from exc
    if result.recording_id is not None:
        recording = session.get(Recording, result.recording_id)
        return {
            "kind": "track",
            "recording": _local_recording_out(session, recording).model_dump(by_alias=True) if recording else None,
        }
    r = result.report
    assert r is not None
    return {
        "id": r.playlist_id,
        "title": r.title,
        "kind": result.kind,
        "owner": result.owner,
        "total": r.total,
        "matched": r.matched,
        "skipped": r.skipped,
        "inLibrary": r.in_library,
        "truncated": result.truncated,
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
async def like_song(
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
        # NAHORU (nejnovější první, jako Spotify a import z něj) -- dřív se
        # přidávalo na konec seznamu o stovkách skladeb a nové lajky "nebyly
        # vidět" (živě nahlášeno).
        top = session.exec(
            select(func.min(PlaylistItem.position)).where(PlaylistItem.playlist_id == playlist.id)
        ).one()
        position = (top - 1) if top is not None else 0
        session.add(PlaylistItem(playlist_id=playlist.id, recording_id=recording_id, position=position))
        session.commit()
    # Oblíbená skladba nemůže mít zároveň zlomené srdce (klepnutí na
    # zlomené srdce ho spraví a dá do Oblíbených).
    dislikes = session.exec(
        select(RecordingDislike).where(RecordingDislike.user_id == user_id, RecordingDislike.recording_id == recording_id)
    ).all()
    if dislikes:
        for row in dislikes:
            session.delete(row)
        session.commit()
        send_feedback_later(recording_id, 0, user_id)
    return {"recordingId": recording_id, "liked": True}


@library_router.get("/disliked")
def disliked_songs(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Id skladeb se zlomeným srdcem (viz app/library/dislikes.py)."""
    return {"recordingIds": sorted(disliked_ids(session, current[0]))}


@library_router.post("/disliked/{recording_id}")
async def dislike_song(
    recording_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Zlomené srdce: vyřadí z Oblíbených i ze všech výběrů, LB "hate"."""
    user_id, _device_id = current
    if session.get(Recording, recording_id) is None:
        raise HTTPException(status_code=404, detail="recording nenalezen v katalogu")
    if recording_id not in disliked_ids(session, user_id):
        session.add(RecordingDislike(user_id=user_id, recording_id=recording_id))
    purge_from_snapshots(session, recording_id)
    session.commit()
    unlike_song(recording_id, session=session, current=current)
    # ListenBrainz účet TOHO profilu (jeho token, viz app/listens.token_for).
    send_feedback_later(recording_id, -1, user_id)
    return {"recordingId": recording_id, "disliked": True}


@library_router.delete("/disliked/{recording_id}")
async def undislike_song(
    recording_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    for row in session.exec(
        select(RecordingDislike).where(RecordingDislike.user_id == user_id, RecordingDislike.recording_id == recording_id)
    ).all():
        session.delete(row)
    session.commit()
    send_feedback_later(recording_id, 0, user_id)
    return {"recordingId": recording_id, "disliked": False}


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


# --- Kontrola stažených skladeb Shazamem (app/tools/verify_downloads.py) ---

_VERIFY_REPORT = Path("/data/db/verify_downloads.json")
_VERIFY_LOCK = asyncio.Lock()


def _read_verify_report() -> dict[str, dict]:
    from app.library.download_check import read_report

    return read_report()


def _write_verify_report(report: dict[str, dict]) -> None:
    # Pod zámkem a jen změněné položky -- worker mezitím mohl zapsat
    # výsledek kontroly jiného stažení.
    from app.library.download_check import update_report

    def change(current: dict[str, dict]) -> None:
        current.update(report)

    update_report(change)


@library_router.get("/verify-report")
def verify_report(
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(require_admin),
):
    """Podezřelé skladby z kontroly (Shazam slyší jinou skladbu, soubor nejde
    přečíst) k ručnímu projití v appce. Nic se samo nemaže ani nemění."""
    report = _read_verify_report()
    items = []
    for rid, e in report.items():
        if e.get("verdict") not in ("mismatch", "broken", "suspect") or e.get("review") in ("ok", "relabeled"):
            continue
        rec = session.get(Recording, rid)
        path = e.get("path")
        own = not (path and Path(path).resolve().is_relative_to(MEDIA_ROOT.resolve()))
        items.append({
            "recordingId": rid,
            "title": e.get("title"),
            "artist": e.get("artist"),
            "album": e.get("album"),
            "releaseId": rec.release_id if rec else None,
            "artistId": rec.artist_id if rec else None,
            "verdict": e.get("verdict"),
            "gotTitle": e.get("gotTitle"),
            "gotArtist": e.get("gotArtist"),
            "provider": e.get("provider"),
            "expectedMs": e.get("expectedMs"),
            "actualMs": e.get("actualMs"),
            "ownFile": own,
            "review": e.get("review"),
        })
    items.sort(key=lambda i: (i["review"] is not None, (i["artist"] or "").lower(), (i["title"] or "").lower()))
    return {"items": items}


@library_router.post("/verify/{recording_id}")
async def verify_now(recording_id: str, _current: tuple[str, str] = Depends(require_admin)):
    """"Něco nesedí?" z přehrávače: délka + Shazam pro jednu skladbu hned.
    Výsledek se zapíše i do přehledu kontroly; nic se samo nemění."""
    from app.library.download_check import check_recording
    from app.recognize import RecognizeError

    try:
        entry = await check_recording(recording_id, manual=True)
    except RecognizeError as exc:
        raise HTTPException(status_code=502, detail=f"Shazam teď neodpovídá: {exc}")
    if entry is None:
        raise HTTPException(status_code=404, detail="Skladba ještě není stažená na serveru.")
    path = entry.get("path")
    own = not (path and Path(path).resolve().is_relative_to(MEDIA_ROOT.resolve()))
    return {**{k: entry.get(k) for k in ("verdict", "gotTitle", "gotArtist", "expectedMs", "actualMs", "durationOff")}, "ownFile": own}


@library_router.post("/verify-report/{recording_id}/ok")
async def verify_mark_ok(recording_id: str, _current: tuple[str, str] = Depends(require_admin)):
    """"Je to v pořádku" -- z přehledu zmizí, při další kontrole se neukáže."""
    async with _VERIFY_LOCK:
        report = _read_verify_report()
        if recording_id not in report:
            raise HTTPException(status_code=404, detail="skladba v kontrole není")
        report[recording_id]["review"] = "ok"
        _write_verify_report(report)
    return {"recordingId": recording_id, "review": "ok"}


@library_router.post("/verify-report/{recording_id}/redownload")
async def verify_redownload(
    recording_id: str,
    current: tuple[str, str] = Depends(require_admin),
):
    """"Stáhnout znovu": smaže stažený soubor a stáhne skladbu znovu z jiného
    výsledku (přeskočí dřívější výběr). Vlastní hudba (mimo MEDIA_ROOT) ani
    chráněná alba (Kontrast) se nemažou."""
    from app.provisioning_service import enqueue, get_or_create_job

    user_id, device_id = current
    async with _VERIFY_LOCK:
        report = _read_verify_report()
        entry = report.get(recording_id)
        if entry is None:
            raise HTTPException(status_code=404, detail="skladba v kontrole není")
        if entry.get("verdict") == "protected":
            raise HTTPException(status_code=400, detail="chráněná skladba se nemění")
        with Session(engine) as session:
            asset = session.get(MediaAsset, recording_id)
            path = Path(asset.storage_path) if asset and asset.storage_path else None
            if path is None or not path.resolve().is_relative_to(MEDIA_ROOT.resolve()):
                raise HTTPException(status_code=400, detail="Tohle je soubor z tvé vlastní hudby -- ten appka nemaže.")
            rec = session.get(Recording, recording_id)
            if rec is not None:
                refs = dict(rec.external_refs or {})
                refs["youtubeSkip"] = int(refs.get("youtubeSkip", 0)) + 1
                rec.external_refs = refs
                session.add(rec)
                session.commit()
            _remove_from_library(session, recording_id)
            _asset, job, created = get_or_create_job(session, recording_id, user_id, device_id)
        if job is not None and created:
            await enqueue(job)
        entry["review"] = "redownload"
        _write_verify_report(report)
    return {"recordingId": recording_id, "review": "redownload"}


@library_router.get("/favorite-artists")
def favorite_artists(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Oblíbení interpreti profilu, nejnověji přidaní první."""
    from app.models import FavoriteArtist

    rows = session.exec(
        select(FavoriteArtist).where(FavoriteArtist.user_id == current[0]).order_by(FavoriteArtist.added_at.desc())  # type: ignore[attr-defined]
    ).all()
    out = []
    for row in rows:
        artist = session.get(Artist, row.artist_id)
        if artist is not None:
            out.append(
                {
                    "id": artist.id,
                    "name": artist.name,
                    "imageUrl": artist.images[0] if artist.images else None,
                    "addedAt": _iso(row.added_at),
                }
            )
    return out


@library_router.post("/favorite-artists/{artist_id}")
def add_favorite_artist(
    artist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    from app.models import FavoriteArtist

    if session.get(Artist, artist_id) is None:
        raise HTTPException(status_code=404, detail="Interpret neexistuje.")
    exists = session.exec(
        select(FavoriteArtist).where(FavoriteArtist.user_id == current[0], FavoriteArtist.artist_id == artist_id)
    ).first()
    if exists is None:
        session.add(FavoriteArtist(user_id=current[0], artist_id=artist_id))
        session.commit()
    return {"artistId": artist_id, "favorite": True}


@library_router.delete("/favorite-artists/{artist_id}")
def remove_favorite_artist(
    artist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    from app.models import FavoriteArtist

    for row in session.exec(
        select(FavoriteArtist).where(FavoriteArtist.user_id == current[0], FavoriteArtist.artist_id == artist_id)
    ).all():
        session.delete(row)
    session.commit()
    return {"artistId": artist_id, "favorite": False}


@library_router.post("/albums/{release_id}/download")
async def download_album(release_id: str, current: tuple[str, str] = Depends(get_current_user)):
    """"Stáhnout celé album": nejdřív složka alba ze Soulseeku (jedna verze
    od jednoho člověka), pak stažení všech skladeb, co ještě nejsou."""
    from app.library.album_download import plan_album
    from app.provisioning_service import enqueue, get_or_create_job

    plan = await plan_album(release_id)
    user_id, device_id = current
    queued = 0
    with Session(engine) as session:
        for rec in session.exec(select(Recording).where(Recording.release_id == release_id)).all():
            _asset, job, created = get_or_create_job(session, rec.id, user_id, device_id)
            if job is not None and created:
                await enqueue(job)
                queued += 1
    return {**plan, "queued": queued}


@library_router.delete("/imported-releases/{release_id}")
async def delete_imported_release(release_id: str, current: tuple[str, str] = Depends(get_current_user)):
    """Smaže album přidané z odkazu na YouTube (nebo ručně přiřazené): stažené
    soubory, skladby i album. Skladby s historií poslechů zůstanou (bez alba),
    ať se nesmaže Wrapped. Oficiální alba z katalogu takhle smazat nejde."""
    from app.catalog.cache import CACHE_PREFIX
    from app.models import Listen, ListenLater, PlaylistItem
    from app.redis_bus import get_redis

    with Session(engine) as session:
        release = session.get(Release, release_id)
        if release is None:
            raise HTTPException(status_code=404, detail="Album neexistuje.")
        if (release.external_refs or {}).get("source") not in ("youtube", "manual"):
            raise HTTPException(status_code=400, detail="Smazat jde jen album přidané z YouTube.")
        artist_id = release.artist_id
        deleted = kept = 0
        for rec in session.exec(select(Recording).where(Recording.release_id == release_id)).all():
            _remove_from_library(session, rec.id)
            for model, column in ((LibraryEntry, LibraryEntry.recording_id), (PlaylistItem, PlaylistItem.recording_id)):
                for row in session.exec(select(model).where(column == rec.id)).all():
                    session.delete(row)
            for row in session.exec(select(ListenLater).where(ListenLater.target_id == rec.id)).all():
                session.delete(row)
            if session.exec(select(Listen).where(Listen.recording_id == rec.id)).first() is not None:
                rec.release_id = None  # historie poslechů zůstává
                session.add(rec)
                kept += 1
                continue
            asset = session.get(MediaAsset, rec.id)
            if asset is not None:
                session.delete(asset)
            session.delete(rec)
            deleted += 1
        for row in session.exec(select(ListenLater).where(ListenLater.target_id == release_id)).all():
            session.delete(row)
        session.delete(release)
        session.commit()
    r = get_redis()
    async for key in r.scan_iter(match=f"{CACHE_PREFIX}swr:discography:v1:{artist_id}:*"):
        await r.delete(key)
    return {"deleted": deleted, "keptWithHistory": kept}


@library_router.post("/tracks/{recording_id}/wrong-version")
async def wrong_version(recording_id: str, current: tuple[str, str] = Depends(get_current_user)):
    """"Špatná verze -- stáhnout jinou": zapamatuje si přesný zdroj staženého
    souboru (Soulseek soubor / YouTube video) jako odmítnutý, soubor smaže a
    stáhne skladbu znovu z jiného zdroje. Vlastní hudba (mimo MEDIA_ROOT) a
    vlastní alba (Kontrast) se nemění."""
    from app.catalog.identity import is_own_id
    from app.provisioning_service import enqueue, get_or_create_job

    user_id, device_id = current
    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
        asset = session.get(MediaAsset, recording_id)
        if rec is None or asset is None or not asset.storage_path:
            raise HTTPException(status_code=404, detail="Skladba není stažená.")
        artist = session.get(Artist, rec.artist_id) if rec.artist_id else None
        if is_own_id(rec.mbid) or (artist is not None and is_own_id(artist.mbid)):
            raise HTTPException(status_code=400, detail="Vlastní hudba se znovu nestahuje.")
        if not Path(asset.storage_path).resolve().is_relative_to(MEDIA_ROOT.resolve()):
            raise HTTPException(status_code=400, detail="Tohle je soubor z tvé vlastní hudby -- ten appka nemaže.")
        refs = dict(rec.external_refs or {})
        key = refs.get("sourceKey")
        if not key and asset.source_provider == "youtube" and refs.get("youtubeUrl"):
            key = f"youtube:{str(refs['youtubeUrl']).rsplit('=', 1)[-1]}"
        rejected = list(refs.get("rejectedSources") or [])
        if key and key not in rejected:
            rejected.append(key)
        refs["rejectedSources"] = rejected
        # Starší stažení bez uloženého zdroje: aspoň přeskočit dřívější výběr.
        if not key:
            refs["youtubeSkip"] = int(refs.get("youtubeSkip", 0)) + 1
        refs.pop("sourceKey", None)
        refs.pop("youtubeUrl", None)
        rec.external_refs = refs
        session.add(rec)
        session.commit()
        _remove_from_library(session, recording_id)
        _asset, job, created = get_or_create_job(session, recording_id, user_id, device_id)
    if job is not None and created:
        await enqueue(job)
    return {"recordingId": recording_id, "rejected": key, "jobId": job.id if job else None}


@library_router.post("/verify-report/{recording_id}/relabel")
async def verify_relabel(recording_id: str, _current: tuple[str, str] = Depends(require_admin)):
    """"Shazam má pravdu" u VLASTNÍ hudby: soubor je v pořádku, jen ho sken
    přiřadil ke špatné skladbě (živě: Marsyas vedený jako Aleš Procházka).
    Soubor se nemění -- přeřadí se k interpretovi a skladbě, kterou slyší
    Shazam. Chráněná alba (Kontrast) se nemění."""
    from app.library.matching import find_or_create_artist, find_or_create_recording
    from app.library.scanner import _reassign_media_asset

    async with _VERIFY_LOCK:
        report = _read_verify_report()
        entry = report.get(recording_id)
        if entry is None:
            raise HTTPException(status_code=404, detail="skladba v kontrole není")
        if entry.get("verdict") == "protected":
            raise HTTPException(status_code=400, detail="chráněná skladba se nemění")
        got_title, got_artist = entry.get("gotTitle"), entry.get("gotArtist")
        if not got_title or not got_artist:
            raise HTTPException(status_code=400, detail="Shazam skladbu nepoznal -- není k čemu přeřadit.")
        with Session(engine) as session:
            asset = session.get(MediaAsset, recording_id)
            if asset is None or not asset.storage_path:
                raise HTTPException(status_code=404, detail="soubor nenalezen")
            artist = find_or_create_artist(session, got_artist)
            target = find_or_create_recording(session, artist, got_title)
            if target.id != recording_id:
                _reassign_media_asset(
                    session, asset, target.id, Path(asset.storage_path), asset.source_provider or "local"
                )
        entry["review"] = "relabeled"
        entry["relabeledTo"] = target.id
        _write_verify_report(report)
    return {"recordingId": recording_id, "review": "relabeled", "newRecordingId": target.id}


# --- Rozposlouchaná alba/playlisty napříč zařízeními ---------------------


def _progress_out(p: CollectionProgress) -> dict:
    return {
        "recordingId": p.recording_id,
        "title": p.title,
        "index": p.idx,
        "total": p.total,
        "positionMs": p.position_ms,
        "deviceId": p.device_id,
        "updatedAt": p.updated_at.isoformat(),
    }


@library_router.get("/progress")
def list_progress(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    rows = session.exec(select(CollectionProgress).where(CollectionProgress.user_id == current[0])).all()
    return {"items": {r.route: _progress_out(r) for r in rows}}


class ProgressIn(CamelModel):
    route: str
    recording_id: str
    title: str = ""
    index: int = 0
    total: int = 0
    position_ms: int = 0


@library_router.put("/progress")
def put_progress(
    body: ProgressIn,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, device_id = current
    row = session.exec(
        select(CollectionProgress).where(CollectionProgress.user_id == user_id, CollectionProgress.route == body.route)
    ).first()
    if row is None:
        row = CollectionProgress(user_id=user_id, route=body.route, recording_id=body.recording_id)
    row.recording_id = body.recording_id
    row.title = body.title
    row.idx = body.index
    row.total = body.total
    row.position_ms = body.position_ms
    row.device_id = device_id
    row.updated_at = utcnow()
    session.add(row)
    session.commit()
    return _progress_out(row)


@library_router.delete("/progress")
def delete_progress(
    route: str = Query(...),
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    for row in session.exec(
        select(CollectionProgress).where(CollectionProgress.user_id == current[0], CollectionProgress.route == route)
    ).all():
        session.delete(row)
    session.commit()
    return {"route": route, "deleted": True}


@library_router.get("/export")
def export_library(current: tuple[str, str] = Depends(get_current_user)):
    """ZIP s oblíbenými, playlisty, historií a "Poslechnout později" --
    CSV pro TuneMyMusic (převod do Spotify apod.) + úplný JSON."""
    from fastapi.responses import Response as RawResponse

    from app.library.export import build_export
    from app.models import AppUser

    user_id, _ = current
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        name = user.name if user else "profil"
        data = build_export(session, user_id, name)
    stamp = utcnow().strftime("%Y-%m-%d")
    return RawResponse(
        content=data,
        media_type="application/zip",
        headers={"Content-Disposition": f'attachment; filename="opentify-export-{stamp}.zip"'},
    )


@library_router.get("/soulseek")
async def soulseek_overview(_admin=Depends(require_admin)):
    """Knihovna › Server (admin): co sdílíme na Soulseeku a kdo si co od nás
    stáhl (slskd API, jen čtení)."""
    import os

    base, key = os.environ.get("SLSKD_URL"), os.environ.get("SLSKD_API_KEY")
    if not base or not key:
        raise HTTPException(status_code=503, detail="Soulseek není nastavený.")
    headers = {"X-API-Key": key}
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            app_state = (await client.get(f"{base}/api/v0/application", headers=headers)).json()
            uploads = (
                await client.get(f"{base}/api/v0/transfers/uploads", headers=headers, params={"includeRemoved": "true"})
            ).json()
    except (httpx.HTTPError, ValueError) as exc:
        raise HTTPException(status_code=502, detail="Soulseek (slskd) teď neodpovídá.") from exc
    shares = app_state.get("shares") or {}
    items = []
    for user in uploads or []:
        for directory in user.get("directories", []):
            for f in directory.get("files", []):
                name = (f.get("filename") or "").replace("\\", "/")
                items.append({
                    "user": user.get("username"),
                    "file": name.rsplit("/", 1)[-1],
                    "folder": name.rsplit("/", 2)[-2] if name.count("/") >= 1 else "",
                    "state": f.get("state") or "",
                    "done": "Succeeded" in (f.get("state") or ""),
                    "at": f.get("endedAt") or f.get("requestedAt") or f.get("enqueuedAt"),
                })
    items.sort(key=lambda i: i["at"] or "", reverse=True)
    return {
        "connected": "LoggedIn" in str((app_state.get("server") or {}).get("state") or ""),
        "sharedFiles": shares.get("files", 0),
        "sharedFolders": shares.get("directories", 0),
        "downloads": sum(1 for i in items if i["done"]),
        "users": len({i["user"] for i in items if i["done"]}),
        "items": items[:200],
    }


class YoutubeLinkIn(BaseModel):
    url: str
    kind: str | None = None  # track | playlist | album | live | soundtrack
    artist_name: str | None = None
    title: str | None = None
    year: int | None = None  # rok vydání alba (neoficiální alba ho jinde nemají)


@library_router.post("/import/youtube-inspect")
async def youtube_inspect(body: YoutubeLinkIn, _current: tuple[str, str] = Depends(get_current_user)):
    """Co je za YouTube odkazem (název, kanál, videa) -- appka se pak zeptá,
    jestli je to skladba, playlist, album interpreta nebo koncert."""
    from app.library.youtube_link import YoutubeLinkError, inspect_youtube_link

    try:
        return await inspect_youtube_link(body.url)
    except YoutubeLinkError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc


@library_router.post("/import/youtube")
async def youtube_import(
    body: YoutubeLinkIn,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    from app.library.youtube_link import YoutubeLinkError, import_youtube_link

    try:
        result = await import_youtube_link(
            session, current[0], body.url, kind=body.kind or "track", artist_name=body.artist_name, title=body.title,
            year=body.year,
        )
    except YoutubeLinkError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    if result["kind"] == "track":
        recording = session.get(Recording, result["recordingId"])
        result["recording"] = _local_recording_out(session, recording).model_dump(by_alias=True) if recording else None
    if result["kind"] in ("album", "live", "soundtrack"):
        from app.catalog.cache import CACHE_PREFIX
        from app.redis_bus import get_redis

        r = get_redis()
        async for key in r.scan_iter(match=f"{CACHE_PREFIX}swr:discography:v1:{result['artistId']}:*"):
            await r.delete(key)
    return result
