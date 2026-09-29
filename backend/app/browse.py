"""Procházet -- kategorie jako na Spotify (nálady: Spánek, Soustředění,
Chill...; žánry: Rock, Jazz...). Každá má vlastní stránku s playlisty, a u
žánrů i populárními skladbami, alby a interprety.

Zdroje (zdarma, bez klíče):
  - Deezer hledání playlistů podle klíčového slova -- redakční playlisty
    Deezeru ("... - Deezer ... Editor") mají přednost, jsou kvalitní a
    udržované.
  - Deezer žánrové žebříčky `/chart/{genre}/tracks` -> skladby, z nich alba
    a interpreti (Deezer `/genre/{id}/artists` vrací pro každý žánr stejné
    globální jméno, nepoužitelné).

Playlisty se do katalogu převezmou až při otevření (`open_deezer_playlist`),
ne dopředu -- šetří to Deezer i databázi.
"""

from __future__ import annotations

from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from sqlmodel import Session, select

from app.catalog.cache import cached_json
from app.catalog.deezer import get_deezer_client
from app.db import engine
from app.home import generators as g
from app.models import GLOBAL_PLAYLIST_OWNER, Artist, Playlist, PlaylistKind, Recording, Release
from app.utils import utcnow

CATEGORY_TTL_S = 12 * 60 * 60
PLAYLIST_FRESH = timedelta(hours=24)


@dataclass(frozen=True)
class Category:
    id: str
    title: str
    group: str  # mood | genre | soundtrack
    color: str  # hex, barva dlaždice
    query: str  # Deezer hledání playlistů
    genre_id: int | None = None
    icon: str = "music"


CATEGORIES: list[Category] = [
    # Nálady a chvíle
    Category("sleep", "Spánek", "mood", "#3B4A8C", "sleep", icon="bedtime"),
    Category("focus", "Soustředění", "mood", "#2F7F7A", "focus", icon="psychology"),
    Category("chill", "Chill", "mood", "#6A5ACD", "chill", icon="spa"),
    Category("workout", "Cvičení", "mood", "#D2572B", "workout", icon="fitness"),
    Category("party", "Párty", "mood", "#C2308A", "party", icon="celebration"),
    Category("feelgood", "Dobrá nálada", "mood", "#E0A21B", "feel good", icon="sunny"),
    Category("romance", "Romantika", "mood", "#B8325A", "love songs", icon="favorite"),
    Category("sad", "Smutné", "mood", "#4F6275", "sad songs", icon="rainy"),
    Category("morning", "Ráno", "mood", "#D98A3D", "morning coffee", icon="coffee"),
    Category("roadtrip", "Na cesty", "mood", "#3E8E5E", "road trip", icon="car"),
    # Žánry
    Category("pop", "Pop", "genre", "#E0457B", "pop hits", 132),
    Category("hiphop", "Rap / Hip Hop", "genre", "#8C5A2B", "hip hop", 116),
    Category("rock", "Rock", "genre", "#B33A3A", "rock classics", 152),
    Category("indie", "Alternativa / Indie", "genre", "#5E7D3A", "indie", 85),
    Category("electronic", "Elektronika", "genre", "#2B6CB0", "electronic", 106),
    Category("dance", "Dance", "genre", "#7A3FB8", "dance hits", 113),
    Category("rnb", "R&B", "genre", "#8A3B6E", "r&b", 165),
    Category("jazz", "Jazz", "genre", "#A06A2C", "jazz", 129),
    Category("classical", "Klasika", "genre", "#6B6B4A", "classical", 98),
    Category("folk", "Folk / Akustická", "genre", "#7A6A4F", "folk acoustic", 466),
    Category("metal", "Metal", "genre", "#3A3A3A", "metal", 464),
    Category("soul", "Soul / Funk", "genre", "#B0662B", "soul funk", 169),
    # Soundtracky -- redakce "Deezer Soundtracks Editor" + playlisty od lidí
    # (herní rádia typu GTA, filmové OST...).
    Category("games", "Herní soundtracky", "soundtrack", "#3F7D52", "video game soundtrack", icon="gamepad"),
    Category("movies", "Filmy a seriály", "soundtrack", "#6B3F8A", "movie soundtrack", icon="movie"),
]

_BY_ID = {c.id: c for c in CATEGORIES}


def get_category(category_id: str) -> Category | None:
    return _BY_ID.get(category_id)


def list_categories() -> list[dict[str, Any]]:
    return [{"id": c.id, "title": c.title, "group": c.group, "color": c.color, "icon": c.icon} for c in CATEGORIES]


async def _category_playlists(c: Category) -> list[dict[str, Any]]:
    return await search_playlists(c.query)


async def search_playlists(
    query: str, limit: int = 12, min_tracks: int = 15, max_tracks: int = 250
) -> list[dict[str, Any]]:
    """Playlisty z Deezeru podle dotazu -- redakční napřed, pak od lidí
    (GTA rádia, soundtracky...). Do katalogu se převezmou až při otevření.
    Rozsah počtu skladeb odfiltruje prázdné a obří "vše možné" playlisty."""
    dz = get_deezer_client()
    items = await dz.search_typed("playlist", query, 25) or []
    editorial = [p for p in items if "deezer" in ((p.get("user") or {}).get("name") or "").lower()]
    others = [p for p in items if p not in editorial and min_tracks <= (p.get("nb_tracks") or 0) <= max_tracks]
    out = []
    for p in (editorial + others)[:limit]:
        if not p.get("id"):
            continue
        out.append(
            {
                "deezerId": str(p["id"]),
                "title": p.get("title") or "",
                "pictureUrl": p.get("picture_xl") or p.get("picture_big") or p.get("picture_medium"),
                "trackCount": p.get("nb_tracks"),
                "editorial": p in editorial,
            }
        )
    return out


def _genre_tracks_and_more(c: Category, recording_ids: list[str]) -> dict[str, Any]:
    from app.home.service import AlbumCardOut, _recording_out

    tracks, albums, artists = [], [], []
    seen_rel, seen_art = set(), set()
    with Session(engine) as session:
        for rid in recording_ids:
            rec = session.get(Recording, rid)
            if rec is None:
                continue
            if len(tracks) < 20:
                tracks.append(_recording_out(session, rec).model_dump(mode="json", by_alias=True))
            rel = session.get(Release, rec.release_id) if rec.release_id else None
            if rel is not None and rel.id not in seen_rel and len(albums) < 12:
                seen_rel.add(rel.id)
                art = session.get(Artist, rel.artist_id)
                albums.append(
                    AlbumCardOut(
                        id=rel.id,
                        title=rel.title,
                        artist_id=rel.artist_id,
                        artist_name=art.name if art else None,
                        release_date=rel.release_date,
                        release_type=rel.release_type,
                        images=rel.images or [],
                    ).model_dump(mode="json", by_alias=True)
                )
            artist = session.get(Artist, rec.artist_id) if rec.artist_id else None
            if artist is not None and artist.id not in seen_art and len(artists) < 12:
                seen_art.add(artist.id)
                artists.append({"id": artist.id, "name": artist.name, "images": artist.images or []})
    return {"tracks": tracks, "albums": albums, "artists": artists}


async def _genre_recording_ids(c: Category) -> list[str]:
    """Skladby žánrového žebříčku -- z uloženého snapshotu Domů, jinak
    čerstvě z Deezeru (a uloží se jako snapshot)."""
    source = f"deezer:chart:genre:{c.genre_id}"
    with Session(engine) as session:
        playlist = session.exec(
            select(Playlist).where(Playlist.owner_user_id == GLOBAL_PLAYLIST_OWNER, Playlist.source == source)
        ).first()
        if playlist is not None:
            from app.models import PlaylistItem

            ids = session.exec(
                select(PlaylistItem.recording_id).where(PlaylistItem.playlist_id == playlist.id).order_by(PlaylistItem.position)
            ).all()
            if ids:
                return list(ids)
    tracks = await get_deezer_client().chart_tracks(c.genre_id or 0, 50)
    if not tracks:
        return []
    ids = g._ingest_tracks(tracks)
    if ids:
        g._save_playlist(
            owner=GLOBAL_PLAYLIST_OWNER, source=source, title=c.title, description=f"Žebříček žánru {c.title} podle Deezeru",
            kind=PlaylistKind.GENRE, section="browse", recording_ids=ids, cover_urls=g._covers_for(ids), ttl=g.DAILY_TTL,
        )
    return ids


async def category_page(c: Category) -> dict[str, Any]:
    async def build() -> dict[str, Any]:
        page: dict[str, Any] = {
            "id": c.id,
            "title": c.title,
            "group": c.group,
            "color": c.color,
            "icon": c.icon,
            "playlists": await _category_playlists(c),
            "tracks": [],
            "albums": [],
            "artists": [],
        }
        if c.genre_id:
            ids = await _genre_recording_ids(c)
            page.update(_genre_tracks_and_more(c, ids))
        return page

    return await cached_json(f"browse:v2:{c.id}", CATEGORY_TTL_S, build, is_empty=lambda p: not p.get("playlists"))


async def open_deezer_playlist(deezer_id: str, title_hint: str | None = None) -> str | None:
    """Převezme Deezer playlist do katalogu (sdílený, jen ke čtení) a vrátí
    id našeho playlistu. Čerstvý (< 24 h) se jen vrátí."""
    source = f"deezer:playlist:{deezer_id}"
    with Session(engine) as session:
        existing = session.exec(
            select(Playlist).where(Playlist.owner_user_id == GLOBAL_PLAYLIST_OWNER, Playlist.source == source)
        ).first()
        if existing is not None and existing.generated_at and utcnow() - existing.generated_at < PLAYLIST_FRESH:
            return existing.id
    dz = get_deezer_client()
    meta = await dz.playlist(deezer_id)
    tracks = await dz.playlist_tracks(deezer_id, 100)
    if not tracks:
        return existing.id if existing is not None else None
    ids = g._ingest_tracks(tracks)
    if not ids:
        return existing.id if existing is not None else None
    title = (meta or {}).get("title") or title_hint or "Playlist"
    description = (meta or {}).get("description") or None
    picture = (meta or {}).get("picture_xl") or (meta or {}).get("picture_big")
    return g._save_playlist(
        owner=GLOBAL_PLAYLIST_OWNER,
        source=source,
        title=title,
        description=description,
        kind=PlaylistKind.EDITORIAL,
        section="browse",
        recording_ids=ids,
        cover_urls=[picture] if picture else g._covers_for(ids),
        ttl=g.DAILY_TTL,
    )
