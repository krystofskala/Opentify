"""Podžánry a styly ze štítků Last.fm -- tisíce stylů, aniž by zahltily
seznam žánrů: každý hlavní žánr má ručně vybranou řadu podžánrů (čipy na
stránce žánru) a KAŽDÝ štítek (i z interpreta) má automatickou stránku:
mix, hlavní interpreti, zásadní alba, popis a příbuzné styly.
"""

from __future__ import annotations

import asyncio
import random
import re
from typing import Any

from sqlmodel import Session, select

from app.catalog import lastfm
from app.catalog.artwork import _normalize
from app.catalog.cache import cached_json
from app.catalog.identity import is_own_artist
from app.db import engine
from app.utils import utcnow

# Ručně vybrané podžánry (štítky Last.fm) -- pořadí = jak se ukážou.
SUBGENRES: dict[str, tuple[str, ...]] = {
    # Nálady: styly, které k nim sedí (stránka nálady › Styly k náladě).
    "sleep": ("ambient", "new age", "drone", "neoclassical", "dark ambient", "lullaby"),
    "focus": ("lo-fi", "post-rock", "minimal", "neoclassical", "ambient", "math rock", "downtempo"),
    "chill": ("lo-fi", "downtempo", "chillwave", "trip-hop", "dream pop", "bossa nova", "neo-soul"),
    "workout": ("edm", "trap", "drum and bass", "hard rock", "metalcore", "dubstep", "big beat"),
    "party": ("house", "dance-pop", "disco", "reggaeton", "electro house", "nu-disco", "funk"),
    "feelgood": ("funk", "disco", "indie pop", "soul", "surf rock", "motown", "power pop"),
    "romance": ("soul", "rnb", "slow jams", "neo-soul", "bossa nova", "chanson", "jazz vocal"),
    "sad": ("slowcore", "sadcore", "emo", "singer-songwriter", "dream pop", "shoegaze", "indie folk"),
    "morning": ("acoustic", "indie folk", "bossa nova", "jazz", "folk pop", "soft rock"),
    "roadtrip": ("classic rock", "heartland rock", "americana", "indie rock", "synthwave", "southern rock"),
    "pop": ("synthpop", "dream pop", "indie pop", "electropop", "art pop", "k-pop", "dance-pop", "bedroom pop", "pop rock", "chamber pop"),
    "hiphop": ("trap", "boom bap", "conscious hip hop", "underground hip hop", "jazz rap", "lo-fi", "grime", "drill", "cloud rap", "czech rap"),
    "rock": ("classic rock", "alternative rock", "hard rock", "punk rock", "grunge", "progressive rock", "psychedelic rock", "post-rock", "garage rock", "britpop"),
    "indie": ("indie rock", "indie folk", "indie pop", "shoegaze", "post-punk", "lo-fi", "math rock", "emo", "slowcore", "art rock"),
    "electronic": ("house", "techno", "ambient", "drum and bass", "dubstep", "idm", "synthwave", "trip-hop", "downtempo", "electronica"),
    "dance": ("house", "deep house", "eurodance", "disco", "nu disco", "trance", "edm", "uk garage", "hardstyle", "electro house"),
    "rnb": ("neo-soul", "contemporary r&b", "alternative rnb", "new jack swing", "funk", "quiet storm", "motown", "soul"),
    "jazz": ("bebop", "cool jazz", "hard bop", "jazz fusion", "smooth jazz", "free jazz", "vocal jazz", "swing", "latin jazz", "nu jazz", "gypsy jazz"),
    "classical": ("baroque", "romantic", "classical period", "contemporary classical", "opera", "piano", "chamber music", "minimalism", "choral", "modern classical"),
    "folk": ("indie folk", "folk rock", "americana", "singer-songwriter", "celtic", "contemporary folk", "freak folk", "anti-folk", "chamber folk", "czech folk"),
    "metal": ("heavy metal", "thrash metal", "death metal", "black metal", "doom metal", "metalcore", "progressive metal", "power metal", "nu metal", "sludge"),
    "soul": ("funk", "neo-soul", "northern soul", "motown", "southern soul", "psychedelic soul", "disco", "gospel"),
    "country": ("outlaw country", "alt-country", "americana", "country rock", "honky tonk", "bro-country", "red dirt", "western swing", "country pop", "texas country"),
    "bluegrass": ("progressive bluegrass", "newgrass", "old-time", "traditional bluegrass", "jamgrass", "americana", "string band", "appalachian", "gospel bluegrass", "dawg music"),
    "blues": ("delta blues", "chicago blues", "electric blues", "blues rock", "texas blues", "piedmont blues", "soul blues", "acoustic blues"),
    "reggae": ("roots reggae", "dub", "ska", "dancehall", "rocksteady", "lovers rock", "reggae fusion"),
    "latin": ("reggaeton", "salsa", "bachata", "cumbia", "latin pop", "tango", "bossa nova", "flamenco", "latin rock"),
    "brazil": ("mpb", "bossa nova", "samba", "tropicalia", "forro", "baile funk", "brazilian jazz"),
    "african": ("afrobeat", "afrobeats", "highlife", "amapiano", "soukous", "desert blues", "ethio-jazz", "mbalax"),
    "asian": ("k-pop", "j-pop", "city pop", "j-rock", "c-pop", "anime", "visual kei", "mandopop"),
    "indian": ("bollywood", "filmi", "indian classical", "carnatic", "punjabi", "bhangra", "sufi"),
    "kids": ("children's music", "lullaby", "disney", "nursery rhymes"),
}

# Štítky, které nejsou styl (Last.fm je plný "seen live", "female vocalists"...).
_NOT_STYLE = {
    "seen live", "favorites", "favourite", "favorite", "love", "awesome", "beautiful", "male vocalists",
    "female vocalists", "female vocalist", "male vocalist", "under 2000 listeners", "my favorite", "albums i own",
    "spotify", "check out", "00s", "10s", "20s", "90s", "80s", "70s", "60s", "50s", "british", "american",
    "usa", "uk", "canadian", "australian", "german", "french", "swedish", "czech", "slovak",
    # Nálepky z artist.getTopTags, které nic neříkají. Národnosti a nástroje
    # ("norwegian", "harmonica") zůstávají -- přání majitele, u blues dávají smysl.
    "vocal", "vocals", "male", "female", "singer", "songwriter", "band", "duo", "cover", "covers", "live",
    "favourites", "favorite songs", "favourite songs", "all", "good", "cool",
}
_DECADE = re.compile(r"^\d{2,4}s$")

TAG_TTL_S = 12 * 60 * 60
MIX_SIZE = 40


async def _none() -> None:
    return None


_running: dict[str, asyncio.Task] = {}


def _background(key: str, coro) -> None:
    """Jedno dopočítání na pozadí na klíč (opakované otevření stránky ho
    nespouští znovu)."""
    if key in _running and not _running[key].done():
        coro.close()
        return
    # Bez `mark_background`: na výsledek klient hned čeká (`/browse/tag-mix`,
    # `/browse/tag-for-you` se připojí ke stejné úloze) -- priorita pozadí
    # by zdržela právě to, co uživatel otevřel (revize 7. 10.).
    _running[key] = asyncio.create_task(coro)


async def _cached_only(key: str) -> Any:
    import json

    from app.catalog.cache import CACHE_PREFIX
    from app.redis_bus import get_redis

    raw = await get_redis().get(CACHE_PREFIX + key)
    return json.loads(raw) if raw is not None else None


async def tag_mix(tag: str) -> dict[str, Any]:
    """"X · nejoblíbenější" (Last.fm) -- zvlášť, skládá se nejdéle."""
    from app.home import generators as g
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistKind

    t = slug(tag)

    async def build() -> dict[str, Any]:
        tracks = await lastfm.tag_top_tracks(t, limit=120)
        random.Random(f"tag:{t}:{utcnow().date().isoformat()}").shuffle(tracks)
        ids = await _resolve_tracks(tracks, MIX_SIZE)
        if not ids:
            return {"playlistId": None}
        return {
            "playlistId": g._save_playlist(
                owner=GLOBAL_PLAYLIST_OWNER, source=f"browse:tag:{t}", title=f"{title_of(t)} · nejoblíbenější",
                description=f"{title_of(t)} -- co posluchači Last.fm pouštějí nejvíc", kind=PlaylistKind.GENRE,
                section="browse", recording_ids=ids, cover_urls=g._covers_for(ids[:4]), ttl=g.DAILY_TTL,
            )
        }

    return await cached_json(f"tag:mix:v1:{t}", TAG_TTL_S, build, is_empty=lambda v: not v.get("playlistId"))


async def tag_playlists(tag: str) -> list[dict[str, Any]]:
    from app import browse as _browse

    t = slug(tag)
    return await cached_json(
        f"tag:playlists:v1:{t}", TAG_TTL_S, lambda: _browse.search_playlists(t, 10, popular=True), is_empty=lambda v: not v
    )


def _for_you_ready(tag: str, user_id: str) -> str | None:
    """Dnešní "Pro tebe · X", je-li už složený."""
    from app.models import Playlist

    with Session(engine) as session:
        p = session.exec(
            select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == f"personal:tag:{slug(tag)}")
        ).first()
        if p is not None and p.generated_at and p.generated_at.date() == utcnow().date():
            return p.id
    return None


def playlist_card(playlist_id: str | None) -> dict[str, Any] | None:
    from app.home.service import _card
    from app.models import Playlist

    if not playlist_id:
        return None
    with Session(engine) as session:
        pl = session.get(Playlist, playlist_id)
        return _card(session, pl).model_dump(mode="json", by_alias=True) if pl else None


def slug(tag: str) -> str:
    return tag.strip().lower()


def title_of(tag: str) -> str:
    from app.home.czech import TAG_TITLES

    if slug(tag) in TAG_TITLES:  # "czech rock" -> "Český rock"
        return TAG_TITLES[slug(tag)]
    return " ".join(w if w.isupper() else (w[:1].upper() + w[1:]) for w in tag.strip().split())


def is_style(tag: str) -> bool:
    t = slug(tag)
    return bool(t) and t not in _NOT_STYLE and not _DECADE.match(t) and len(t) <= 40


def parent_genres(tag: str) -> list[str]:
    """Hlavní žánry, pod které podžánr patří."""
    t = slug(tag)
    return [g for g, subs in SUBGENRES.items() if t in subs]


async def artist_tags(name: str, limit: int = 6) -> list[str]:
    info = await lastfm.artist_info(name)
    return [t.lower() for t in (info or {}).get("tags") or [] if is_style(t)][:limit]


async def _resolve_tracks(items: list[dict[str, str]], limit: int) -> list[str]:
    """(interpret, název) z Last.fm -> naše skladby přes Deezer, souběžně,
    jen přesná shoda interpreta."""
    from app.catalog.artwork import _normalize
    from app.catalog.deezer import get_deezer_client
    from app.home import generators as g

    dz = get_deezer_client()
    sem = asyncio.Semaphore(6)

    async def one(item: dict[str, str]) -> dict[str, Any] | None:
        async with sem:
            try:
                found = await dz.find_track(item["artist"], item["title"])
            except Exception:  # noqa: BLE001
                return None
        if not found or not found.get("id"):
            return None
        if _normalize((found.get("artist") or {}).get("name", "")) != _normalize(item["artist"]):
            return None
        return found

    found = [f for f in await asyncio.gather(*(one(i) for i in items[: limit + limit // 2])) if f]
    return (await asyncio.to_thread(g._ingest_tracks, found[:limit])) if found else []


_for_you_inflight: dict[tuple[str, str], asyncio.Task] = {}


async def tag_for_you(tag: str, user_id: str) -> str | None:
    """Souběžná volání (stránka stylu spustí výpočet na pozadí a klient se
    hned ptá `/browse/tag-for-you`) sdílí jeden výpočet -- dřív se vkus
    profilu načítal dvakrát naráz (audit výkonu 7. 10.)."""
    key = (slug(tag), user_id)
    task = _for_you_inflight.get(key)
    if task is None or task.done() or task.get_loop() is not asyncio.get_running_loop():
        task = asyncio.ensure_future(_tag_for_you(tag, user_id))
        _for_you_inflight[key] = task
        task.add_done_callback(lambda t, k=key: _for_you_inflight.pop(k, None) if _for_you_inflight.get(k) is t else None)
    return await asyncio.shield(task)


async def _tag_for_you(tag: str, user_id: str) -> str | None:
    """"Pro tebe · X": skladby stylu podle profilu -- tvoje (poslouchané,
    oblíbené, z knihovny) od interpretů, kteří ten styl hrají, doplněné
    nejposlouchanějšími skladbami stylu od jim podobných interpretů. Jednou
    denně; vrací id playlistu nebo None (styl u tebe skoro není)."""
    from app.catalog.lastfm import artist_top_tags
    from app.home import generators as g
    from app.home import lastfm_taste as lt
    from app.home.personal_mixes import load_taste
    from app.models import Playlist, PlaylistKind

    t = slug(tag)
    source = f"personal:tag:{t}"
    today = utcnow().date()
    with Session(engine) as session:
        existing = session.exec(select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == source)).first()
        if existing is not None and existing.generated_at and existing.generated_at.date() == today:
            return existing.id

    taste = await asyncio.to_thread(load_taste, user_id)
    now = utcnow()
    rec_weight: dict[str, float] = {}
    artist_weight: dict[str, float] = {}
    liked = set(taste.liked)
    for rid, artist_id in taste.artist_of.items():
        w = 0.1 + 0.3 * (rid in liked) + 0.05 * taste.listen_counts.get(rid, 0)
        if rid in taste.last_played:
            w += 0.5 ** ((now - taste.last_played[rid]).total_seconds() / 86400 / 30)
        rec_weight[rid] = w
        artist_weight[artist_id] = artist_weight.get(artist_id, 0.0) + w
    # 300, ne 70: styl, který posloucháš jen okrajově (rap u folkaře --
    # Eminem 150., mgk 210.), jinak mix neměl z čeho vzniknout. Štítky
    # interpretů jsou v cache týden, takže je to levné.
    top_artists = sorted(artist_weight, key=lambda a: -artist_weight[a])[:300]
    names = {a: taste.artist_name.get(a) for a in top_artists}
    sem = asyncio.Semaphore(6)

    async def plays_tag(artist_id: str) -> bool:
        name = names.get(artist_id)
        # Vlastní interpret: štítky (i podobní níž) by byly cizí kapely.
        if not name or is_own_artist(artist_id):
            return False
        async with sem:
            tags = await artist_top_tags(name)
        return any(slug(n) == t and c >= 15 for n, c in tags)

    flags = await asyncio.gather(*(plays_tag(a) for a in top_artists))
    tag_artists = [a for a, ok in zip(top_artists, flags) if ok]
    rng = random.Random(f"{source}:{today.isoformat()}")
    own_by_artist: dict[str, list[str]] = {}
    for rid, artist_id in taste.artist_of.items():
        if artist_id in tag_artists:
            own_by_artist.setdefault(artist_id, []).append(rid)
    own: list[str] = []
    for artist_id in tag_artists:
        picks = sorted(own_by_artist.get(artist_id, []), key=lambda r: -rec_weight[r] * (0.7 + 0.6 * rng.random()))
        own += picks[:3]
    rng.shuffle(own)
    own = own[:26]

    # Objevy: nejposlouchanější skladby stylu (Last.fm) od interpretů, které
    # už posloucháš, nebo jim podobných -- ne celý svět stylu.
    known_names = {_normalize(names[a] or "") for a in tag_artists}
    similar: set[str] = set()
    for a in tag_artists[:6]:
        similar |= {_normalize(n) for n, _m in await lt.similar_artist_names(names[a] or "", 25)}
    pool = [x for x in await lastfm.tag_top_tracks(t, limit=200) if _normalize(x["artist"]) in (known_names | similar)]
    rng.shuffle(pool)
    # Málo vlastních (okrajový styl): víc objevů, ať mix vznikne i tak.
    want = 14 if len(own) >= 8 else 24
    discovery = [r for r in await _resolve_tracks(pool, want + 6) if r not in set(own)][:want]
    if len(own) + len(discovery) < 12 or not own:
        return None
    ids: list[str] = []
    while own or discovery:
        ids += own[:2]
        own = own[2:]
        ids += discovery[:1]
        discovery = discovery[1:]
    ids = list(dict.fromkeys(ids))[:40]
    return g._save_playlist(
        owner=user_id, source=source, title=f"Tvůj mix · {title_of(t)}",
        description=f"{title_of(t)} podle tebe -- tvoje oblíbené a objevy od podobných interpretů",
        kind=PlaylistKind.PERSONAL_MIX, section="tag", recording_ids=ids, cover_urls=g._covers_for(ids[:4]),
        ttl=g.DAILY_TTL,
    )


async def tag_page(tag: str, user_id: str | None = None) -> dict[str, Any]:
    """Stránka stylu: mix (náš playlist ze štítku), interpreti, alba, popis,
    příbuzné styly. Cache 12 h, mix se mění denně."""
    from app import browse
    from app.home import generators as g
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistKind

    t = slug(tag)

    async def build() -> dict[str, Any]:
        # Bez mixu (40 skladeb přes Deezer = ~18 s) -- ten zvlášť, `tag_mix`.
        artist_names, album_items = await asyncio.gather(lastfm.tag_top_artists(t, 30), lastfm.tag_top_albums(t, 20))
        artist_ids, album_ids, about = await asyncio.gather(
            browse._resolve_artists(artist_names, 18, set()),
            browse._resolve_albums(album_items, 12),
            lastfm.tag_summary(t),
        )
        return {"artistIds": artist_ids, "albumIds": album_ids, "about": about}

    # Hlavní obsah hned; osobní mix a playlisty z Deezeru jen když už jsou
    # hotové (jinak se dopočítají na pozadí a klient si je dotáhne zvlášť,
    # `/browse/tag-for-you`, `/browse/tag-playlists`) -- stránka dřív čekala
    # na všechno najednou.
    data = await cached_json(f"tag:page:v3:{t}", TAG_TTL_S, build, is_empty=lambda v: not v.get("artistIds"))
    mix_cached = await _cached_only(f"tag:mix:v1:{t}")
    if mix_cached is None:
        _background(f"mix:{t}", tag_mix(t))
    data = {**data, "playlistId": (mix_cached or {}).get("playlistId")}
    for_you_id = _for_you_ready(t, user_id) if user_id else None
    if user_id and for_you_id is None:
        _background(f"for-you:{t}:{user_id}", tag_for_you(t, user_id))
    playlists = await _cached_only(f"tag:playlists:v1:{t}")
    if playlists is None:
        _background(f"playlists:{t}", tag_playlists(t))
    from app.home.service import _card
    from app.models import Artist, Playlist, Release

    with Session(engine) as session:
        mix = None
        if data.get("playlistId"):
            pl = session.get(Playlist, data["playlistId"])
            mix = _card(session, pl).model_dump(mode="json", by_alias=True) if pl else None
        for_you = None
        if for_you_id:
            pl = session.get(Playlist, for_you_id)
            for_you = _card(session, pl).model_dump(mode="json", by_alias=True) if pl else None
        artists = [browse._artist_card(a) for a in (session.get(Artist, i) for i in data.get("artistIds") or []) if a]
        albums = [browse._album_card(session, r) for r in (session.get(Release, i) for i in data.get("albumIds") or []) if r]
    parents = parent_genres(t)
    siblings: list[str] = []
    for p in parents:
        siblings += [s for s in SUBGENRES[p] if s != t and s not in siblings]
    return {
        "tag": t,
        "title": title_of(t),
        "mix": mix,
        "forYou": for_you,
        "playlists": playlists or [],
        "topArtists": artists,
        "albums": albums,
        "about": data.get("about"),
        "parents": [
            {"id": c.id, "title": c.title, "group": c.group, "color": c.color, "icon": c.icon}
            for c in (browse.get_category(p) for p in parents)
            if c is not None
        ],
        "related": siblings[:10],
    }


async def warm_style_pages() -> int:
    """Denně na pozadí: stránky 8 nejsilnějších stylů profilu (Tvé styly)
    předem -- otevřou se hned i napoprvé (studená stránka = desítky
    dotazů na Deezer)."""
    from app.home import generators as g
    from app.home.personal_mixes import styles_key
    from app.models import HomeSnapshot

    user_id = g.home_user()
    with Session(engine) as session:
        snap = session.get(HomeSnapshot, styles_key(user_id))
        styles = list((snap.payload or {}).get("tags") or [])[:12] if snap else []
    for tag in styles:
        try:
            await tag_page(tag, None)
            await tag_mix(tag)
            await tag_playlists(tag)
            await tag_for_you(tag, user_id)
        except Exception:  # noqa: BLE001 - jeden styl nesmí zastavit ostatní
            continue
    return len(styles)
