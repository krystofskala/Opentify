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

import asyncio
import logging
import re
from dataclasses import dataclass
from datetime import timedelta
from typing import Any

from sqlmodel import Session, select

from app.catalog.cache import cached_json, cached_json_swr


async def _swr(key: str, fresh_s: int, build, is_empty) -> Any:
    """Stránka Procházet hned z uložené verze, obnova na pozadí, až je starší
    než `fresh_s` (dřív po vypršení 12 h čekal první návštěvník 10-60 s --
    simulace 5. 10.: 29 z 34 kategorií). Prázdný výsledek (výpadek zdroje)
    se neukládá."""
    last: dict[str, Any] = {}

    async def fetch() -> Any:
        value = await build()
        last["v"] = value
        return None if is_empty(value) else value

    value = await cached_json_swr(key, fresh_s, fetch)
    return value if value is not None else last.get("v")
from app.catalog.deezer import get_deezer_client
from app.db import engine
from app.home import generators as g
from app.models import GLOBAL_PLAYLIST_OWNER, Artist, Playlist, PlaylistKind, Recording, Release
from app.utils import utcnow

logger = logging.getLogger(__name__)

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
    # Podkategorie (Soundtracky › Hry...) -- v mřížce Procházet se nezobrazuje.
    parent: str | None = None


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
    Category("country", "Country", "genre", "#A8743A", "country", 84),
    # Bluegrass nemá na Deezeru vlastní žánr -- skladby z bluegrassových
    # playlistů (viz `genre_rail`).
    Category("bluegrass", "Bluegrass", "genre", "#5B7F3B", "bluegrass"),
    Category("blues", "Blues", "genre", "#2F4F7F", "blues", 153),
    Category("reggae", "Reggae", "genre", "#3F8F3F", "reggae", 144),
    Category("latin", "Latinskoamerická", "genre", "#D0632B", "latin hits", 197),
    Category("brazil", "Brazilská", "genre", "#2E9E6B", "brasil", 75),
    Category("african", "Africká", "genre", "#C88A1E", "afrobeats", 2),
    Category("asian", "Asijská / K-pop", "genre", "#C2457A", "k-pop", 16),
    Category("indian", "Indická / Bollywood", "genre", "#D9532F", "bollywood", 81),
    Category("kids", "Pro děti", "genre", "#4DA3D9", "kids songs", 95),
    # Soundtracky -- redakce "Deezer Soundtracks Editor" + playlisty od lidí
    # (herní rádia typu GTA, filmové OST...).
    Category("games", "Herní soundtracky", "soundtrack", "#3F7D52", "video game soundtrack", icon="gamepad"),
    Category("movies", "Filmy a seriály", "soundtrack", "#6B3F8A", "movie soundtrack", icon="movie"),
]

_BY_ID = {c.id: c for c in CATEGORIES}

# Vlastní zdroj pro žánry, kde Deezer nestačí (tátova srdcovka bluegrass):
# ručně vybraní interpreti od klasiků po současnost + česká scéna. Řada na
# Domů = jejich nejlepší skladby z Deezeru, každý den jinak promíchané.
SEED_ARTISTS: dict[str, tuple[str, ...]] = {
    "bluegrass": (
        # Zakladatelé a klasika
        "Bill Monroe", "Flatt & Scruggs", "The Stanley Brothers", "Ralph Stanley", "Jimmy Martin",
        "The Osborne Brothers", "Jim & Jesse", "Reno & Smiley", "Doc Watson", "Mac Wiseman",
        "The Country Gentlemen", "The Seldom Scene", "J.D. Crowe & The New South", "Tony Rice",
        "Del McCoury Band", "Hot Rize", "Bluegrass Album Band", "Ricky Skaggs", "Tim O'Brien",
        "Sam Bush", "David Grisman", "Béla Fleck", "Jerry Douglas", "Tony Trischka", "Peter Rowan",
        # 90. léta až dnes
        "Alison Krauss & Union Station", "Rhonda Vincent", "Lonesome River Band", "Blue Highway",
        "IIIrd Tyme Out", "Dailey & Vincent", "Michael Cleveland", "Nickel Creek", "Punch Brothers",
        "Chris Thile", "Billy Strings", "Molly Tuttle", "Sierra Hull", "Bronwyn Keith-Hynes",
        "The Infamous Stringdusters", "Greensky Bluegrass", "Yonder Mountain String Band",
        "Steep Canyon Rangers", "The Steeldrivers", "Della Mae", "Special Consensus",
        "Balsam Range", "Sister Sadie", "Danny Paisley", "AJ Lee & Blue Summit",
        # Česká scéna
        "Druhá tráva", "Poutníci", "Robert Křesťan", "Monogram",
    ),
}
SEED_TOP = 10  # z kolika nejlepších skladeb interpreta se vybírá
SEED_PER_ARTIST = 3


def get_category(category_id: str) -> Category | None:
    return _BY_ID.get(category_id)


def list_categories() -> list[dict[str, Any]]:
    return [
        {"id": c.id, "title": c.title, "group": c.group, "color": c.color, "icon": c.icon}
        for c in CATEGORIES
        if c.parent is None
    ]


async def _category_playlists(c: Category) -> list[dict[str, Any]]:
    return await search_playlists(c.query)


async def search_playlists(
    query: str, limit: int = 12, min_tracks: int = 15, max_tracks: int = 250, *, popular: bool = False
) -> list[dict[str, Any]]:
    """Playlisty z Deezeru podle dotazu -- redakční napřed, pak od lidí
    (GTA rádia, soundtracky...). Do katalogu se převezmou až při otevření.
    Rozsah počtu skladeb odfiltruje prázdné a obří "vše možné" playlisty.
    `popular`: ty od lidí seřadit podle počtu fanoušků (detail playlistu)."""
    dz = get_deezer_client()
    items = await dz.search_typed("playlist", query, 25) or []
    editorial = [p for p in items if "deezer" in ((p.get("user") or {}).get("name") or "").lower()]
    others = [p for p in items if p not in editorial and min_tracks <= (p.get("nb_tracks") or 0) <= max_tracks]
    if popular and others:
        details = await asyncio.gather(*(dz.playlist(str(p["id"])) for p in others[:15] if p.get("id")), return_exceptions=True)
        fans = {str(d.get("id")): int(d.get("fans") or 0) for d in details if isinstance(d, dict) and d.get("id")}
        others = sorted(others[:15], key=lambda p: -fans.get(str(p.get("id")), 0))
        for p in others:
            p["_fans"] = fans.get(str(p.get("id")))
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
                "fans": p.get("_fans"),
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
        expired = (
            playlist is not None
            and playlist.expires_at is not None
            and _aware(playlist.expires_at) < utcnow()
        )
        if playlist is not None and not expired:
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


def _playlist_ids(playlist_id: str) -> list[str]:
    from app.models import PlaylistItem

    with Session(engine) as session:
        return list(
            session.exec(
                select(PlaylistItem.recording_id)
                .where(PlaylistItem.playlist_id == playlist_id)
                .order_by(PlaylistItem.position)  # type: ignore[arg-type]
            ).all()
        )


RAIL_FRESH = timedelta(hours=24)


def rail_key(category_id: str) -> str:
    return f"genre-rail:{category_id}"


# MusicBrainz tagy (přes ListenBrainz) ke každému žánru -- rozšíří řadu
# o skladby, které Deezer žebříček ani naše playlisty nemají.
LB_TAGS: dict[str, tuple[str, ...]] = {
    "pop": ("pop",), "hiphop": ("hip hop",), "rock": ("rock",), "indie": ("indie", "indie rock"),
    "electronic": ("electronic",), "dance": ("dance", "house"), "rnb": ("rnb", "contemporary r&b"),
    "jazz": ("jazz",), "classical": ("classical",), "folk": ("folk",), "metal": ("metal",),
    "soul": ("soul", "funk"), "country": ("country",), "bluegrass": ("bluegrass",), "blues": ("blues",),
    "reggae": ("reggae",), "latin": ("latin", "reggaeton"), "brazil": ("mpb", "bossa nova", "samba"),
    "african": ("afrobeat", "afrobeats"), "asian": ("k-pop", "j-pop"), "indian": ("bollywood", "filmi"),
    "kids": ("children's music",),
}
LB_MIN_PERCENT = 60  # slabší vazba (tag celého alba/interpreta) přinášela omyly
LB_EXTRA = 30  # skladeb z tagů navíc
RAIL_SIZE = 100


def _track_key(session: Session, recording_id: str) -> tuple[str, str] | None:
    from app.catalog.artwork import _normalize

    rec = session.get(Recording, recording_id)
    if rec is None:
        return None
    artist = session.get(Artist, rec.artist_id) if rec.artist_id else None
    return (_normalize(artist.name if artist else ""), _normalize(rec.title))


async def _lb_tag_tracks(c: Category, limit: int) -> list[str]:
    """Skladby žánru podle tagů komunity na MusicBrainz, spárované s Deezerem
    (ISRC, jinak interpret + název). Denně jiný výběr."""
    import random

    from app.catalog.artwork import _normalize
    from app.recommendations.listenbrainz import ListenBrainzError, get_listenbrainz_public_client

    tags = LB_TAGS.get(c.id)
    if not tags:
        return []
    lb = get_listenbrainz_public_client()
    rows: list[dict[str, Any]] = []
    for tag in tags:
        try:
            rows += await lb.tag_radio(tag)
        except (ListenBrainzError, Exception):  # noqa: BLE001 -- LB je jen bonus
            continue
    good = [r for r in rows if r.get("recording_mbid") and (r.get("source") == "recording" or (r.get("percent") or 0) >= LB_MIN_PERCENT)]
    mbids = list(dict.fromkeys(r["recording_mbid"] for r in good))
    random.Random(f"lb:{c.id}:{utcnow().date().isoformat()}").shuffle(mbids)
    dz = get_deezer_client()
    tracks: list[dict[str, Any]] = []
    for i in range(0, min(len(mbids), limit * 3), 25):
        try:
            meta = await lb.recording_metadata(mbids[i : i + 25])
        except Exception:  # noqa: BLE001
            break
        for mbid in mbids[i : i + 25]:
            m = meta.get(mbid) or {}
            artist = ((m.get("artist") or {}).get("name") or "").strip()
            title = ((m.get("recording") or {}).get("name") or "").strip()
            if not artist or not title:
                continue
            found = None
            for isrc in (m.get("recording") or {}).get("isrcs") or []:
                found = await dz.find_track_by_isrc(isrc)
                if found and found.get("id"):
                    break
            if not (found and found.get("id")):
                found = await dz.find_track(artist, title)
            if not found or not found.get("id"):
                continue
            # Jen když Deezer našel opravdu tohohle interpreta.
            if _normalize((found.get("artist") or {}).get("name", "")) != _normalize(artist):
                continue
            tracks.append(found)
            if len(tracks) >= limit:
                break
        if len(tracks) >= limit:
            break
    return await asyncio.to_thread(g._ingest_tracks, tracks) if tracks else []


# Last.fm štítky (posluchači) -- jinak pojmenované než MusicBrainz.
LASTFM_TAGS: dict[str, tuple[str, ...]] = {
    **LB_TAGS,
    "hiphop": ("hip-hop", "rap"), "rnb": ("rnb",), "kids": ("childrens music",),
    "asian": ("k-pop", "j-pop"), "brazil": ("mpb", "bossa nova"), "african": ("afrobeats", "afrobeat"),
    # Nálady a chvíle -- štítky posluchačů (stejný základ jako žánry).
    "sleep": ("sleep", "calm", "ambient"), "focus": ("focus", "study", "instrumental"),
    "chill": ("chill", "chillout", "mellow"), "workout": ("workout", "gym", "energetic"),
    "party": ("party", "dance", "club"), "feelgood": ("happy", "feel good", "upbeat"),
    "romance": ("love", "romantic", "love songs"), "sad": ("sad", "melancholy", "melancholic"),
    "morning": ("morning", "coffee", "acoustic"), "roadtrip": ("driving", "road trip", "summer"),
}
LASTFM_EXTRA = 40


async def _lastfm_tag_tracks(c: Category, limit: int) -> list[str]:
    """Skladby žánru podle štítků posluchačů Last.fm, spárované s Deezerem
    (interpret + název, jen přesná shoda interpreta). Denně jiný výběr --
    u menších žánrů (bluegrass, country) víc než Deezer i ListenBrainz."""
    import random

    from app.catalog import lastfm
    from app.catalog.artwork import _normalize

    if not lastfm.api_key():
        return []
    rows: list[dict[str, Any]] = []
    for tag in LASTFM_TAGS.get(c.id, ()):
        rows += await lastfm.tag_top_tracks(tag, limit=150)
    seen: set[tuple[str, str]] = set()
    unique = []
    for r in rows:
        key = (_normalize(r["artist"]), _normalize(r["title"]))
        if key not in seen:
            seen.add(key)
            unique.append(r)
    random.Random(f"lastfm:{c.id}:{utcnow().date().isoformat()}").shuffle(unique)
    dz = get_deezer_client()
    tracks: list[dict[str, Any]] = []
    for r in unique[: limit * 3]:
        found = await dz.find_track(r["artist"], r["title"])
        if not found or not found.get("id"):
            continue
        if _normalize((found.get("artist") or {}).get("name", "")) != _normalize(r["artist"]):
            continue
        tracks.append(found)
        if len(tracks) >= limit:
            break
    return await asyncio.to_thread(g._ingest_tracks, tracks) if tracks else []


async def _base_tracks(c: Category) -> list[str]:
    """Základ řady: Deezer žebříček žánru, u bluegrassu vlastní výběr
    interpretů, jinak playlisty se žánrem v názvu."""
    if c.id in SEED_ARTISTS:
        return await _seed_mix(c)
    if c.genre_id:
        return await _genre_recording_ids(c)
    candidates = await search_playlists(c.query, limit=12)
    titled = [p for p in candidates if c.query.lower() in p["title"].lower()] or candidates
    lists: list[list[str]] = []
    for candidate in titled[:3]:
        opened = await open_deezer_playlist(candidate["deezerId"], candidate["title"])
        if opened:
            lists.append(_playlist_ids(opened))
    mixed: list[str] = []
    for i in range(max((len(x) for x in lists), default=0)):
        for ids in lists:
            if i < len(ids) and ids[i] not in mixed:
                mixed.append(ids[i])
    return mixed


async def genre_rail(c: Category, *, force: bool = False) -> str | None:
    """Jedna řada skladeb žánru -- ta samá na Domů (Žánry, připnuté žánry)
    i na stránce žánru v Hledat. Základ (`_base_tracks`) + skladby ze štítků
    Last.fm a tagů ListenBrainz, bez duplicit (stejná nahrávka ani stejný interpret+název).
    Id playlistu se pamatuje v `HomeSnapshot`, obnova denně."""
    from app.models import HomeSnapshot

    with Session(engine) as session:
        snap = session.get(HomeSnapshot, rail_key(c.id))
        if snap is not None and not force and utcnow() - _aware(snap.generated_at) < RAIL_FRESH:
            return snap.payload.get("playlistId")
    base = await _base_tracks(c)
    from_lastfm = await _lastfm_tag_tracks(c, LASTFM_EXTRA)
    extra = await _lb_tag_tracks(c, LB_EXTRA)
    combined: list[str] = []
    seen: set[tuple[str, str]] = set()
    with Session(engine) as session:

        def take(rid: str) -> None:
            key = _track_key(session, rid)
            if rid in combined or key is None or key in seen:
                return
            if c.group == "mood" and _functional(key[0]):
                return
            seen.add(key)
            combined.append(rid)

        # Napřed Deezer (žebříček / výběr), pak Last.fm a ListenBrainz jen
        # doplní, co Deezer neměl (přání: Deezer výsledky první).
        for rid in [*base, *from_lastfm, *extra]:
            if len(combined) >= RAIL_SIZE:
                break
            take(rid)
    if not combined:
        return snap.payload.get("playlistId") if snap is not None else None
    playlist_id = g._save_playlist(
        owner=GLOBAL_PLAYLIST_OWNER, source=f"browse:genre:{c.id}", title=c.title,
        description=f"{c.title} -- populární, klasika i tipy komunity", kind=PlaylistKind.GENRE,
        section="genres", recording_ids=combined, cover_urls=g._covers_for(combined[:4]), ttl=g.DAILY_TTL,
    )
    with Session(engine) as session:
        row = session.get(HomeSnapshot, rail_key(c.id)) or HomeSnapshot(key=rail_key(c.id))
        row.payload = {"playlistId": playlist_id}
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    return playlist_id


async def _seed_mix(c: Category) -> list[str]:
    return await seed_tracks(c.id, SEED_ARTISTS[c.id])


async def seed_tracks(key: str, names: tuple[str, ...] | list[str]) -> list[str]:
    """Nejlepší skladby vybraných interpretů, denně jiný výběr (bluegrass,
    český bluegrass). Interpret se páruje jen při přesné shodě jména (ne
    "nejbližší" výsledek)."""
    import random

    from app.catalog.artwork import _normalize

    dz = get_deezer_client()
    rng = random.Random(f"{key}:{utcnow().date().isoformat()}")
    picked: list[dict[str, Any]] = []
    for name in names:
        found = await dz.search_artist(name, limit=5)
        artist = next((a for a in found if _normalize(a.get("name", "")) == _normalize(name)), None)
        if artist is None or not artist.get("id"):
            continue
        top = await dz.artist_top(str(artist["id"]), SEED_TOP) or []
        # Jen skladby, kde je hlavním interpretem (ne host -- Chris Thile
        # s Lang Langem nebo Renée Fleming bluegrass nejsou).
        top = [t for t in top if str((t.get("artist") or {}).get("id")) == str(artist["id"])]
        picked.extend(rng.sample(top, min(SEED_PER_ARTIST, len(top))))
    rng.shuffle(picked)
    ids = await asyncio.to_thread(g._ingest_tracks, picked)
    # Stejný interpret ne dvakrát za sebou.
    out: list[str] = []
    with Session(engine) as session:
        rest = [(rid, getattr(session.get(Recording, rid), "artist_id", None)) for rid in ids]
    last = None
    while rest:
        i = next((k for k, (_, a) in enumerate(rest) if a != last), 0)
        rid, last = rest.pop(i)
        out.append(rid)
    return out


def _aware(value):
    from datetime import timezone

    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def new_key(category_id: str) -> str:
    return f"genre-new:{category_id}"


NEW_WITHIN_DAYS = 365
# Novinky jen od živých/aktivních -- u legend Deezer vede reedice s datem
# digitálního vydání (živě: Tony Rice, Jimmy Martin jako "novinky").
NEW_SKIP_ARTISTS = {
    "Bill Monroe", "Flatt & Scruggs", "The Stanley Brothers", "Ralph Stanley", "Jimmy Martin",
    "The Osborne Brothers", "Jim & Jesse", "Reno & Smiley", "Doc Watson", "Mac Wiseman",
    "The Country Gentlemen", "J.D. Crowe & The New South", "Tony Rice", "Bluegrass Album Band",
}
_REISSUE = re.compile(
    r"remaster|anniversary|deluxe|expanded|reissue|story|best of|greatest|collection|anthology|essential|hits|complete"
    r"|years|integral|\b(19|20)\d\d\s*[-–]\s*(19|20)?\d\d\b|\bvol(ume)?\.?\s*\d",
    re.I,
)


async def genre_new_releases(c: Category, *, force: bool = False) -> str | None:
    """"Novinky": co interpreti žánru (vlastní výběr, `SEED_ARTISTS`) vydali
    za poslední rok -- nejnovější první, ze každé desky pár skladeb. Jen pro
    žánry s vlastním výběrem interpretů (bluegrass). Obnova denně."""
    from datetime import date

    from app.catalog.artwork import _normalize
    from app.models import HomeSnapshot

    if c.id not in SEED_ARTISTS:
        return None
    with Session(engine) as session:
        snap = session.get(HomeSnapshot, new_key(c.id))
        if snap is not None and not force and utcnow() - _aware(snap.generated_at) < RAIL_FRESH:
            return snap.payload.get("playlistId")
    dz = get_deezer_client()
    cutoff = date.today().toordinal() - NEW_WITHIN_DAYS
    albums: list[dict[str, Any]] = []
    for name in SEED_ARTISTS[c.id]:
        if name in NEW_SKIP_ARTISTS:
            continue
        found = await dz.search_artist(name, limit=5)
        artist = next((a for a in found if _normalize(a.get("name", "")) == _normalize(name)), None)
        if artist is None or not artist.get("id"):
            continue
        for album in await dz.artist_albums(str(artist["id"])) or []:
            if album.get("record_type") == "compile" or _REISSUE.search(album.get("title") or ""):
                continue
            try:
                released = date.fromisoformat(album.get("release_date") or "")
            except ValueError:
                continue
            if released.toordinal() >= cutoff and album.get("id"):
                albums.append({**album, "_date": released, "_artist": artist})
    albums.sort(key=lambda a: a["_date"], reverse=True)
    tracks: list[dict[str, Any]] = []
    seen_albums: set[str] = set()
    for album in albums:
        if album["id"] in seen_albums or len(tracks) >= RAIL_SIZE:
            continue
        seen_albums.add(album["id"])
        items = await dz.album_tracks(str(album["id"])) or []
        own = [t for t in items if str((t.get("artist") or {}).get("id")) == str(album["_artist"]["id"])]
        # Singl celý, z desky první tři skladby.
        for t in own[:3]:
            tracks.append({**t, "album": {"id": album["id"], "title": album.get("title"), "cover_xl": album.get("cover_xl"), "cover_big": album.get("cover_big")}})
    ids = await asyncio.to_thread(g._ingest_tracks, tracks) if tracks else []
    if not ids:
        return snap.payload.get("playlistId") if snap is not None else None
    playlist_id = g._save_playlist(
        owner=GLOBAL_PLAYLIST_OWNER, source=f"browse:new:{c.id}", title=f"Novinky: {c.title}",
        description=f"Co vyšlo za poslední rok -- {c.title.lower()} od klasiků po mladé", kind=PlaylistKind.EDITORIAL,
        section="browse", recording_ids=ids[:RAIL_SIZE], cover_urls=g._covers_for(ids[:4]), ttl=g.DAILY_TTL,
    )
    with Session(engine) as session:
        row = session.get(HomeSnapshot, new_key(c.id)) or HomeSnapshot(key=new_key(c.id))
        row.payload = {"playlistId": playlist_id}
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    return playlist_id


def pinned_genres(user_id: str) -> list[Category]:
    from app.models import AppUser

    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        ids = (user.home_genres if user else None) or []
    return [c for c in (get_category(i) for i in ids) if c is not None and c.group in ("genre", "mood")]


def pinned_soundtracks(user_id: str) -> list[Category]:
    """Soundtracky připnuté na Domů (Herní soundtracky, Filmy a seriály)."""
    from app.models import AppUser

    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        ids = (user.home_genres if user else None) or []
    return [c for c in (get_category(i) for i in ids) if c is not None and c.group == "soundtrack" and c.parent is None]


def _pinned_anywhere() -> set[str]:
    from app.models import AppUser

    with Session(engine) as session:
        return {i for u in session.exec(select(AppUser)).all() for i in (u.home_genres or [])}


async def build_genre_rails() -> int:
    """Generátor Domů: řady všech žánrů (připnuté profily napřed). Každá se
    obnoví jednou denně, mezi nimi `genre_rail` jen vrátí uloženou."""
    from app.models import AppUser

    with Session(engine) as session:
        wanted = {i for u in session.exec(select(AppUser)).all() for i in (u.home_genres or [])}
    pinned = _pinned_anywhere()
    # Žánry vždy (Domů › Žánry), nálady jen když je má někdo připnuté.
    genres = [c for c in CATEGORIES if c.group == "genre" or (c.group == "mood" and c.id in pinned)]
    genres.sort(key=lambda c: c.id not in wanted)
    built = 0
    for c in genres:
        if await genre_rail(c):
            built += 1
        if c.id in wanted:
            if await genre_new_releases(c):
                built += 1
            try:
                await build_showcase(c)
            except Exception:  # noqa: BLE001 -- vitrína je bonus, řada žánru stačí
                logging.getLogger(__name__).exception("vitrína žánru %s selhala", c.id)
            # Stránky podžánrů připnutých žánrů dopředu (první otevření jinak ~10 s).
            from app.tags import SUBGENRES, tag_page

            for sub in SUBGENRES.get(c.id, ()):
                try:
                    await tag_page(sub)
                except Exception:  # noqa: BLE001
                    logging.getLogger(__name__).exception("podžánr %s selhal", sub)
    return built


def showcase_key(category_id: str) -> str:
    return f"genre-showcase:{category_id}"


async def build_showcase(c: Category) -> None:
    """Ukázka stránky žánru pro Domů: žánrový mix napřed, pak Novinky,
    nová a zásadní alba a interpreti na přeskáčku."""
    from app.models import HomeSnapshot

    extras = await genre_extras(c)
    with Session(engine) as session:
        rail = session.get(HomeSnapshot, rail_key(c.id))
        new = session.get(HomeSnapshot, new_key(c.id))
        payload = {
            "railId": (rail.payload or {}).get("playlistId") if rail else None,
            "newId": (new.payload or {}).get("playlistId") if new else None,
            "newReleaseIds": (extras.get("newReleaseIds") or [])[:5],
            "artistIds": (extras.get("artistIds") or [])[:6],
            "classicIds": (extras.get("classicIds") or [])[:5],
        }
        row = session.get(HomeSnapshot, showcase_key(c.id)) or HomeSnapshot(key=showcase_key(c.id))
        row.payload = payload
        row.generated_at = utcnow()
        session.add(row)
        session.commit()


def showcase_items(session: Session, payload: dict[str, Any]) -> list[dict[str, Any]]:
    """Karty vitríny (`build_showcase`) -- playlisty, alba, interpreti."""
    from app.home.service import _card

    items: list[dict[str, Any]] = []
    for pid in (payload.get("railId"), payload.get("newId")):
        pl = session.get(Playlist, pid) if pid else None
        if pl is not None:
            items.append({"itemType": "playlist", **_card(session, pl).model_dump(mode="json", by_alias=True)})
    new = [r for r in (session.get(Release, i) for i in payload.get("newReleaseIds") or []) if r is not None]
    classic = [r for r in (session.get(Release, i) for i in payload.get("classicIds") or []) if r is not None]
    artists = [a for a in (session.get(Artist, i) for i in payload.get("artistIds") or []) if a is not None]
    for i in range(max(len(new), len(classic), len(artists))):
        for group, kind in ((new, "new"), (artists, "artist"), (classic, "classic")):
            if i >= len(group):
                continue
            x = group[i]
            if kind == "artist":
                items.append({"itemType": "artist", **_artist_card(x)})
            else:
                items.append({"itemType": "album", "badge": "Novinka" if kind == "new" else None, **_album_card(session, x)})
    return items


# Podobné žánry (odkazy dole na stránce žánru).
RELATED_GENRES: dict[str, tuple[str, ...]] = {
    "sleep": ("focus", "chill", "sad"), "focus": ("chill", "sleep", "morning"), "chill": ("focus", "morning", "romance"),
    "workout": ("party", "roadtrip", "feelgood"), "party": ("workout", "feelgood", "dance"),
    "feelgood": ("party", "roadtrip", "morning"), "romance": ("chill", "sad", "rnb"), "sad": ("romance", "sleep", "chill"),
    "morning": ("feelgood", "chill", "focus"), "roadtrip": ("feelgood", "workout", "rock"),
    "pop": ("dance", "rnb", "indie", "asian"), "hiphop": ("rnb", "soul", "african", "pop"),
    "rock": ("metal", "indie", "blues", "folk"), "indie": ("rock", "folk", "electronic", "pop"),
    "electronic": ("dance", "indie", "pop", "hiphop"), "dance": ("electronic", "pop", "latin", "african"),
    "rnb": ("soul", "hiphop", "pop", "jazz"), "jazz": ("blues", "soul", "classical", "brazil"),
    "classical": ("jazz", "folk", "kids", "indie"), "folk": ("bluegrass", "country", "indie", "blues"),
    "metal": ("rock", "indie", "electronic", "blues"), "soul": ("rnb", "jazz", "blues", "hiphop"),
    "country": ("bluegrass", "folk", "blues", "rock"), "bluegrass": ("country", "folk", "blues", "jazz"),
    "blues": ("jazz", "soul", "rock", "bluegrass"), "reggae": ("african", "latin", "hiphop", "soul"),
    "latin": ("brazil", "reggae", "dance", "pop"), "brazil": ("latin", "jazz", "african", "reggae"),
    "african": ("reggae", "hiphop", "latin", "dance"), "asian": ("pop", "dance", "indian", "electronic"),
    "indian": ("asian", "pop", "african", "classical"), "kids": ("pop", "classical", "folk", "dance"),
}
EXTRAS_TTL_S = 12 * 60 * 60


def _album_card(session: Session, release: Release) -> dict[str, Any]:
    from app.home.service import AlbumCardOut

    art = session.get(Artist, release.artist_id) if release.artist_id else None
    return AlbumCardOut(
        id=release.id,
        title=release.title,
        artist_id=release.artist_id,
        artist_name=art.name if art else None,
        release_date=release.release_date,
        release_type=release.release_type,
        images=release.images or [],
    ).model_dump(mode="json", by_alias=True)


def _artist_card(artist: Artist) -> dict[str, Any]:
    return {"id": artist.id, "name": artist.name, "images": artist.images or []}


async def _resolve_artists(names: list[str], limit: int, skip: set[str]) -> list[str]:
    """Jména (Last.fm / vlastní výběr) -> naši interpreti přes Deezer, jen
    přesná shoda jména. Hledání souběžně, pořadí podle vstupu."""
    from app.catalog.artwork import _normalize
    from app.catalog.deezer_ingest import ingest_artist

    dz = get_deezer_client()
    unique: list[str] = []
    seen_names: set[str] = set()
    for name in names:
        key = _normalize(name)
        if key and key not in seen_names:
            seen_names.add(key)
            unique.append(name)
    unique = unique[: limit * 2]
    sem = asyncio.Semaphore(6)

    async def look(name: str) -> dict[str, Any] | None:
        async with sem:
            try:
                hits = await dz.search_artist(name, limit=5)
            except Exception:  # noqa: BLE001
                return None
        return next((h for h in hits if _normalize(h.get("name") or "") == _normalize(name)), None)

    hits = await asyncio.gather(*(look(n) for n in unique))
    ids: list[str] = []
    with Session(engine) as session:
        for hit in hits:
            if hit is None:
                continue
            artist = ingest_artist(session, hit)
            if artist is not None and artist.id not in ids and artist.id not in skip:
                ids.append(artist.id)
            if len(ids) >= limit:
                break
        session.commit()
    return ids


async def _resolve_albums(items: list[dict[str, str]], limit: int) -> list[str]:
    """(interpret, album) z Last.fm -> naše vydání přes Deezer (přesný název).
    Hledání souběžně, pořadí podle vstupu."""
    from app.catalog.artwork import _normalize
    from app.catalog.deezer_ingest import ingest_album, ingest_artist

    dz = get_deezer_client()
    sem = asyncio.Semaphore(6)

    async def look(item: dict[str, str]) -> dict[str, Any] | None:
        async with sem:
            try:
                hits = await dz.search_album(item["artist"], item["title"])
            except Exception:  # noqa: BLE001
                return None
        return next(
            (
                h
                for h in hits
                if _normalize(h.get("title") or "") == _normalize(item["title"])
                and _normalize((h.get("artist") or {}).get("name") or "") == _normalize(item["artist"])
            ),
            None,
        )

    hits = await asyncio.gather(*(look(i) for i in items[: limit * 2]))
    ids: list[str] = []
    with Session(engine) as session:
        for hit in hits:
            if hit is None:
                continue
            artist = ingest_artist(session, hit.get("artist") or {})
            release = ingest_album(session, hit, artist) if artist else None
            if release is not None and release.id not in ids:
                ids.append(release.id)
            if len(ids) >= limit:
                break
        session.commit()
    return ids


def _ingest_dz_albums(albums: list[dict[str, Any]], limit: int) -> list[str]:
    from app.catalog.deezer_ingest import ingest_album, ingest_artist

    ids: list[str] = []
    with Session(engine) as session:
        for a in albums:
            artist = ingest_artist(session, a.get("artist") or {})
            release = ingest_album(session, a, artist) if artist else None
            if release is not None and release.id not in ids:
                ids.append(release.id)
            if len(ids) >= limit:
                break
        session.commit()
    return ids


async def _first_release_year(artist: str, title: str) -> int | None:
    """Rok prvního vydání alba podle MusicBrainz (release group), nebo None."""
    from app.catalog.musicbrainz import MusicBrainzError, get_musicbrainz_client

    def q(text: str) -> str:
        return text.replace("\\", " ").replace('"', " ")

    if not artist or not title:
        return None
    data: dict[str, Any] = {}
    for attempt in range(4):
        try:
            data = await get_musicbrainz_client().search(
                "release-group", f'releasegroup:"{q(title)}" AND artist:"{q(artist)}"', 5, 0
            )
            break
        except MusicBrainzError:
            # Fronta MusicBrainz plná (backfilly na pozadí) -- chvíli počkat.
            await asyncio.sleep(3 * (attempt + 1))
    else:
        return None
    years = []
    for rg in data.get("release-groups") or []:
        if (rg.get("score") or 0) < 90:
            continue
        date_text = rg.get("first-release-date") or ""
        if len(date_text) >= 4 and date_text[:4].isdigit():
            years.append(int(date_text[:4]))
    return min(years) if years else None


async def _recent_albums(artist_ids: list[str], limit: int) -> list[str]:
    """Alba a EP hlavních interpretů žánru z posledního roku (bez kompilací
    a reedic), nejnovější první."""
    from datetime import date

    from app.catalog.deezer_ingest import ingest_album

    dz = get_deezer_client()
    cutoff = date.today().toordinal() - NEW_WITHIN_DAYS
    found: list[tuple[date, dict[str, Any], str]] = []
    for aid in artist_ids:
        with Session(engine) as session:
            artist = session.get(Artist, aid)
            dzid = artist.deezer_id if artist else None
        if not dzid:
            continue
        for album in await dz.artist_albums(dzid) or []:
            if album.get("record_type") not in ("album", "ep") or _REISSUE.search(album.get("title") or ""):
                continue
            try:
                released = date.fromisoformat(album.get("release_date") or "")
            except ValueError:
                continue
            if released.toordinal() >= cutoff:
                found.append((released, album, aid))
    found.sort(key=lambda x: x[0], reverse=True)
    ids: list[str] = []
    checked = 0
    with Session(engine) as session:
        names = {aid: (a.name if (a := session.get(Artist, aid)) else "") for aid in {x[2] for x in found}}
    # MusicBrainz (1 dotaz/s, čeká i sekundy) MIMO DB session -- dřív se
    # spojení drželo přes všechna čekání (audit výkonu 7. 10.).
    for _released, album, aid in found:
        if checked < 30:
            # Deezer dává reedicím datum digitálního vydání (Rubber Soul jako
            # novinka) -- MusicBrainz zná datum PRVNÍHO vydání.
            checked += 1
            first = await _first_release_year(names.get(aid, ""), album.get("title") or "")
            if first is not None and first < date.today().year - 1:
                continue
        with Session(engine) as session:
            release = ingest_album(session, album, session.get(Artist, aid))
            session.commit()
            release_id = release.id if release is not None else None
            # Vydání, které už známe se starým datem (MusicBrainz), není novinka.
            known_year = (release.release_date or "")[:4] if release is not None else ""
        if known_year.isdigit() and int(known_year) < date.today().year - 1:
            continue
        if release_id is not None and release_id not in ids:
            ids.append(release_id)
        if len(ids) >= limit:
            break
    return ids


# Výplňová "funkční" hudba (Tabata Songs, Absolute Sleep Music, Relaxing
# Piano Bar...) -- u nálad zaplaví štítky posluchačů; ven z interpretů i řady.
_FUNCTIONAL = re.compile(
    r"\b(music|songs|sleep|sleeping|relax\w*|tabata|workout|fitness|gym|study|studying|baby|babies|lullab\w*|"
    r"meditation|spa|yoga|white noise|nature sounds|piano bar|lounge|ambience|ambient sounds|hits|"
    r"karaoke|instrumentals?|tones|healing|binaural|asmr|focus|concentration|deep sleep)\b",
    re.I,
)


def _functional(name: str | None) -> bool:
    from app.recommendations.anti_ai_filter import AntiAIFilter

    return bool(name) and (bool(_FUNCTIONAL.search(name)) or AntiAIFilter().is_blocked_text(name))


async def genre_extras(c: Category) -> dict[str, Any]:
    """Obsah stránky žánru navíc (a ukázka na Domů): nová alba, hlavní
    interpreti, zásadní alba, popis žánru, podobné žánry. Deezer napřed,
    Last.fm doplní (štítky posluchačů). Cache 12 h."""
    from app.catalog import lastfm
    from app.catalog.deezer_ingest import ingest_artist

    async def build() -> dict[str, Any]:
        dz = get_deezer_client()
        tags = LASTFM_TAGS.get(c.id) or (c.query,)
        if c.group == "mood":
            # Interpreti a alba nálady ze stylů, které k ní patří (chill ->
            # lo-fi, downtempo, trip-hop) -- štítek "chill" sám vrací hlavně
            # výplňovou hudbu.
            from app.tags import SUBGENRES

            tags = SUBGENRES.get(c.id, ())[:3] or tags
        # Interpreti: nejposlouchanější se štítkem žánru (Last.fm), u
        # bluegrassu doplní vlastní výběr. Deezer "chart artists" je jen
        # místní žebříček (CZ rap u country), ne žánr.
        names: list[str] = []
        for tag in tags[:2]:
            names += await lastfm.tag_top_artists(tag, 40)
        names += list(SEED_ARTISTS.get(c.id, ()))
        if c.group == "mood":
            names = [n for n in names if not _functional(n)]
        artist_ids = await _resolve_artists(names, 24, set())
        # Nová alba: co hlavní interpreti žánru vydali za poslední rok (alba
        # a EP). Redakce Deezeru míchala reedice klasik s novým datem
        # (Rubber Soul, "Ella Fitzgerald 1960 - 1962"). U bluegrassu vlastní
        # Novinky.
        new_ids: list[str] = []
        if c.id in SEED_ARTISTS:
            new_pl = await genre_new_releases(c)
            if new_pl:
                with Session(engine) as session:
                    for rid in _playlist_ids(new_pl):
                        rec = session.get(Recording, rid)
                        if rec is not None and rec.release_id and rec.release_id not in new_ids:
                            new_ids.append(rec.release_id)
                new_ids = new_ids[:15]
        if not new_ids and c.group == "genre":
            # (Nálada nemá "nová alba" -- interpreti štítku chill nejsou žánr.)
            new_ids = await _recent_albums(artist_ids[:20], 15)
        # Zásadní alba: nejposlouchanější alba se štítkem žánru (Last.fm).
        classic_items: list[dict[str, str]] = []
        for tag in tags[:2]:
            classic_items += await lastfm.tag_top_albums(tag, 30)
        if c.group == "mood":
            classic_items = [i for i in classic_items if not _functional(i.get("artist")) and not _functional(i.get("title"))]
        classic_ids = await _resolve_albums(classic_items, 15)
        about = await lastfm.tag_summary(tags[0])
        return {
            "newReleaseIds": new_ids,
            "artistIds": artist_ids,
            "classicIds": [i for i in classic_ids if i not in new_ids],
            "about": about,
            "related": [r for r in RELATED_GENRES.get(c.id, ()) if r in _BY_ID],
        }

    return await _swr(f"browse:extras:v9:{c.id}", EXTRAS_TTL_S, build, lambda v: not v.get("artistIds"))


def extras_cards(extras: dict[str, Any]) -> dict[str, Any]:
    """Id z `genre_extras` -> karty alb/interpretů (čerstvé obrázky z DB)."""
    with Session(engine) as session:

        def albums(ids: list[str]) -> list[dict[str, Any]]:
            return [_album_card(session, r) for r in (session.get(Release, i) for i in ids) if r is not None]

        artists = [
            _artist_card(a) for a in (session.get(Artist, i) for i in extras.get("artistIds") or []) if a is not None
        ]
        return {
            "newReleases": albums(extras.get("newReleaseIds") or []),
            "classics": albums(extras.get("classicIds") or []),
            "topArtists": artists,
            "about": extras.get("about"),
            "related": [
                {"id": r.id, "title": r.title, "group": r.group, "color": r.color, "icon": r.icon}
                for r in (get_category(i) for i in extras.get("related") or [])
                if r is not None
            ],
        }


def genre_mixes(c: Category, rail_id: str | None, new_id: str | None) -> list[dict[str, Any]]:
    """Naše playlisty žánru jako karty: žánrový mix (stejný jako na Domů)
    a Novinky."""
    from app.home.service import _card

    out = []
    with Session(engine) as session:
        for pid in (rail_id, new_id):
            pl = session.get(Playlist, pid) if pid else None
            if pl is not None:
                out.append(_card(session, pl).model_dump(mode="json", by_alias=True))
    return out


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
        if c.group in ("genre", "mood"):
            # Stejná řada jako na Domů (žebříček/výběr + tagy ListenBrainz);
            # nálady na stejném základu jako žánry (Deezer + Last.fm).
            playlist_id = await genre_rail(c)
            page.update(_genre_tracks_and_more(c, _playlist_ids(playlist_id) if playlist_id else []))
            page["playlistId"] = playlist_id
        return page

    page = await _swr(f"browse:v5:{c.id}", CATEGORY_TTL_S, build, lambda p: not p.get("playlists"))
    if c.group == "soundtrack":
        # Soundtracky jako žánr: alba soundtracků, franšízy (jako interpreti),
        # skladatelé, mixy, podkategorie (app/soundtracks.py).
        from app import soundtracks

        try:
            page = {**page, **await soundtracks.category_extra(c.id)}
        except Exception:  # noqa: BLE001
            logger.exception("soundtracky %s", c.id)
        return page
    if c.group in ("genre", "mood"):
        page = {**page, **extras_cards(await genre_extras(c))}
        # Česky (vlastní text) místo anglického popisu z Last.fm.
        from app.genre_about import ABOUT_CS

        if c.id in ABOUT_CS:
            page["about"] = ABOUT_CS[c.id]
            page["aboutSource"] = None
        elif page.get("about"):
            page["aboutSource"] = "Last.fm"
        new_id = await genre_new_releases(c) if c.id in SEED_ARTISTS else None
        page["mixes"] = genre_mixes(c, page.get("playlistId"), new_id)
        from app.tags import SUBGENRES, title_of

        page["subgenres"] = [{"tag": t, "title": title_of(t)} for t in SUBGENRES.get(c.id, ())]
    return page


async def open_deezer_playlist(deezer_id: str, title_hint: str | None = None) -> str | None:
    """Převezme Deezer playlist do katalogu (sdílený, jen ke čtení) a vrátí
    id našeho playlistu. Čerstvý (< 24 h) se jen vrátí."""
    source = f"deezer:playlist:{deezer_id}"
    with Session(engine) as session:
        existing = session.exec(
            select(Playlist).where(Playlist.owner_user_id == GLOBAL_PLAYLIST_OWNER, Playlist.source == source)
        ).first()
        if existing is not None and existing.generated_at and utcnow() - _aware(existing.generated_at) < PLAYLIST_FRESH:
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


def _known_artists(user_id: str) -> set[str]:
    """Interpreti, které profil zná: poslouchal, má jejich skladbu v Oblíbených
    nebo je má mezi oblíbenými interprety."""
    from app.models import FavoriteArtist, Listen, PlaylistItem

    with Session(engine) as session:
        # DISTINCT v SQL (dřív 119k řádků do Pythonu, 250 ms).
        known = set(
            session.exec(
                select(Recording.artist_id)
                .distinct()
                .join(Listen, Listen.recording_id == Recording.id)
                .where(Listen.user_id == user_id)
            ).all()
        )
        known |= set(
            session.exec(
                select(Recording.artist_id)
                .join(PlaylistItem, PlaylistItem.recording_id == Recording.id)
                .join(Playlist, Playlist.id == PlaylistItem.playlist_id)
                .where(Playlist.owner_user_id == user_id, Playlist.source == "liked-songs")
            ).all()
        )
        known |= set(session.exec(select(FavoriteArtist.artist_id).where(FavoriteArtist.user_id == user_id)).all())
    known.discard(None)
    return known  # type: ignore[return-value]


async def genre_for_you(c: Category, user_id: str) -> dict[str, Any]:
    """"Pro tebe" na stránce žánru: alba žánru od interpretů, které
    posloucháš (novinky napřed), a hlavní interpreti žánru, které ještě
    neznáš."""
    extras = await genre_extras(c)
    known = await asyncio.to_thread(_known_artists, user_id)
    with Session(engine) as session:
        albums = []
        seen: set[str] = set()
        candidates = (extras.get("newReleaseIds") or []) + (extras.get("classicIds") or [])
        # + jejich další alba, co už v katalogu máme
        for rid in candidates:
            rel = session.get(Release, rid)
            if rel is not None and rel.artist_id in known and rel.id not in seen:
                seen.add(rel.id)
                albums.append(_album_card(session, rel))
        discover = [
            _artist_card(a)
            for a in (session.get(Artist, i) for i in extras.get("artistIds") or [])
            if a is not None and a.id not in known
        ]
        yours = [
            _artist_card(a)
            for a in (session.get(Artist, i) for i in extras.get("artistIds") or [])
            if a is not None and a.id in known
        ]
    return {"albums": albums[:12], "discover": discover[:12], "yourArtists": yours[:12]}
