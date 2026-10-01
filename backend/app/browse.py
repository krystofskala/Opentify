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
    i na stránce žánru v Hledat. Základ (`_base_tracks`) + skladby z tagů
    ListenBrainz, bez duplicit (stejná nahrávka ani stejný interpret+název).
    Id playlistu se pamatuje v `HomeSnapshot`, obnova denně."""
    from app.models import HomeSnapshot

    with Session(engine) as session:
        snap = session.get(HomeSnapshot, rail_key(c.id))
        if snap is not None and not force and utcnow() - _aware(snap.generated_at) < RAIL_FRESH:
            return snap.payload.get("playlistId")
    base = await _base_tracks(c)
    extra = await _lb_tag_tracks(c, LB_EXTRA)
    combined: list[str] = []
    seen: set[tuple[str, str]] = set()
    with Session(engine) as session:

        def take(rid: str) -> None:
            key = _track_key(session, rid)
            if rid in combined or key is None or key in seen:
                return
            seen.add(key)
            combined.append(rid)

        # Napřed Deezer (žebříček / výběr), ListenBrainz jen doplní, co Deezer
        # neměl (přání: Deezer výsledky první).
        for rid in [*base, *extra]:
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
    """Nejlepší skladby vybraných interpretů žánru, denně jiný výběr.
    Interpret se páruje jen při přesné shodě jména (ne "nejbližší" výsledek)."""
    import random

    from app.catalog.artwork import _normalize

    dz = get_deezer_client()
    rng = random.Random(f"{c.id}:{utcnow().date().isoformat()}")
    picked: list[dict[str, Any]] = []
    for name in SEED_ARTISTS[c.id]:
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
        found = await dz.search_artist(name, limit=5)
        artist = next((a for a in found if _normalize(a.get("name", "")) == _normalize(name)), None)
        if artist is None or not artist.get("id"):
            continue
        for album in await dz.artist_albums(str(artist["id"])) or []:
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
    return [c for c in (get_category(i) for i in ids) if c is not None and c.group == "genre"]


async def build_genre_rails() -> int:
    """Generátor Domů: řady všech žánrů (připnuté profily napřed). Každá se
    obnoví jednou denně, mezi nimi `genre_rail` jen vrátí uloženou."""
    from app.models import AppUser

    with Session(engine) as session:
        wanted = {i for u in session.exec(select(AppUser)).all() for i in (u.home_genres or [])}
    genres = [c for c in CATEGORIES if c.group == "genre"]
    genres.sort(key=lambda c: c.id not in wanted)
    built = 0
    for c in genres:
        if await genre_rail(c):
            built += 1
        if c.id in wanted and await genre_new_releases(c):
            built += 1
    return built


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
        if c.group == "genre":
            # Stejná řada jako na Domů (žebříček/výběr + tagy ListenBrainz).
            playlist_id = await genre_rail(c)
            page.update(_genre_tracks_and_more(c, _playlist_ids(playlist_id) if playlist_id else []))
            page["playlistId"] = playlist_id
        return page

    return await cached_json(f"browse:v3:{c.id}", CATEGORY_TTL_S, build, is_empty=lambda p: not p.get("playlists"))


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
