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
from pathlib import Path

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, UploadFile
from pydantic import BaseModel
from sqlalchemy import and_, func, or_
from sqlmodel import Session, select

from app.auth import get_current_user
from app.catalog.availability import compute_availability, resolve_artist_name
from app.catalog.schemas import CamelModel, RecordingOut
from app.db import engine, get_session
from app.library.scanner import ScanProgress, get_scan_progress, scan_library
from app.library.dislikes import disliked_ids, send_feedback_later
from app.library.spotify_link import SpotifyLinkError, import_spotify_link
from app.library.spotify_import import (
    LIKED_SONGS_SOURCE,
    LIKED_SONGS_TITLE,
    get_or_create_liked_songs_playlist,
    import_spotify_library,
)
from app.models import (
    Artist,
    MediaAsset,
    MediaAssetStatus,
    Playlist,
    PlaylistItem,
    PlaylistKind,
    Recording,
    RecordingDislike,
    Release,
)

library_router = APIRouter(prefix="/library", tags=["library"])

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
    base_query = select(MediaAsset).where(_IN_LIBRARY)
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
        .where(_IN_LIBRARY)
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
        .where(_IN_LIBRARY)
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
        .where(_IN_LIBRARY)
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
        .where(_IN_LIBRARY)
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
            _IN_LIBRARY,
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
        .where(_IN_LIBRARY, Artist.country == "CZ")
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


@library_router.delete("/tracks/{recording_id}")
def remove_track(
    recording_id: str,
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    """"Odebrat z knihovny" -- neodebírá z Oblíbených ani z playlistů (to
    jsou samostatné akce), jen z "Moje knihovna"."""
    return _remove_from_library(session, recording_id)


@library_router.post("/tracks/remove")
def remove_tracks(
    body: RemoveTracksBody,
    dry_run: bool = Query(default=False, alias="dryRun"),
    session: Session = Depends(get_session),
    _current: tuple[str, str] = Depends(get_current_user),
):
    """`?dryRun=true` -- jen spočítá, co by se stalo (kolik MB se uvolní, co
    se jen skryje), pro potvrzovací sheet v klientovi. Nic nemění."""
    results = [_remove_from_library(session, rid, dry_run) for rid in body.recording_ids[:500]]
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
    user_id, _device_id = current
    raw = await file.read()
    try:
        result = import_spotify_library(session, user_id, raw)
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
        raise HTTPException(status_code=502, detail="Spotify se nepodařilo načíst, zkus to za chvíli.") from exc
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
        # NAHORU (nejnovější první, jako Spotify a import z něj) -- dřív se
        # přidávalo na konec seznamu o stovkách skladeb a nové lajky "nebyly
        # vidět" (živě nahlášeno).
        top = session.exec(
            select(func.min(PlaylistItem.position)).where(PlaylistItem.playlist_id == playlist.id)
        ).one()
        position = (top - 1) if top is not None else 0
        session.add(PlaylistItem(playlist_id=playlist.id, recording_id=recording_id, position=position))
        session.commit()
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
        session.commit()
    unlike_song(recording_id, session=session, current=current)
    send_feedback_later(recording_id, -1)
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
    send_feedback_later(recording_id, 0)
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
