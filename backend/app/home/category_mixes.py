"""Vlastní mixy pro kategorie Procházet ("Tvůj mix · Jazz", "Tvůj mix ·
Spánek") -- jako Spotify: tvoje skladby z dané nálady/žánru + nové od
podobných interpretů.

Žánr interpreta:
  - Deezer: `/artist/{id}/albums` vrací u každého alba `genre_id` -- stejná
    id, na kterých stojí žánrové kategorie (app/browse.py). Podíl alb v
    žánru = příslušnost interpreta. Uloží se do `Artist.external_refs
    ["dzGenres"]`, zjišťuje se jen jednou.
  - Záloha: žánry MusicBrainz u alb tvých skladeb (klíčová slova).

Nálady žánr nemají -- vychází z redakčních playlistů Deezeru dané nálady:
tvoji interpreti, kteří v nich jsou (nebo mají v nich aspoň 3 podobné), a
nové skladby z nich od interpretů podobných tvým.

Na Domů je řada "Tvoje žánry" -- 4 žánry, které posloucháš nejvíc. Sada je
stabilní: jiný žánr vystřídá ten nejméně poslouchaný, až když ho
znatelně (o 15 %) předběhne.
"""

from __future__ import annotations

import asyncio
import logging
import random
from collections import Counter, defaultdict
from typing import Any

from sqlmodel import Session, select

from app import listen_later
from app.browse import CATEGORIES, Category, _category_playlists, get_category
from app.catalog.artwork import _names_match, primary_artist_name
from app.catalog.deezer import get_deezer_client
from app.catalog.identity import is_own_artist
from app.db import engine
from app.home import generators as g
from app.home import personal_mixes as pm
from app.models import Artist, Playlist, PlaylistKind

logger = logging.getLogger(__name__)

MIX_SIZE = 40
FAMILIAR_SHARE = 0.6
MIN_FAMILIAR = 4
MIN_MIX_SIZE = 15
MEMBER_SHARE = 0.25  # interpret patří do žánru, když v něm má aspoň čtvrtinu alb
HOME_PICKS = 4
REPLACE_MARGIN = 1.15
PICKS_KEY = "personal:category-picks"
SECTION = "category_mixes"

# Deezer žánry mimo naše kategorie, které k některé přesto patří.
_DZ_EXTRA: dict[int, str] = {}  # (country a blues mají od 2026-10 vlastní kategorie)
_DZ_TO_CAT = {c.genre_id: c.id for c in CATEGORIES if c.genre_id} | _DZ_EXTRA

# MusicBrainz žánry -> kategorie (podřetězec, jeden žánr může do víc kategorií).
_MB_KEYWORDS: dict[str, tuple[str, ...]] = {
    "indie": ("indie", "alternative", "shoegaze", "lo-fi", "dream pop", "post-punk", "slacker"),
    "folk": ("folk", "bluegrass", "americana", "singer-songwriter", "acoustic", "country"),
    "rock": ("rock", "grunge", "punk"),
    "pop": ("pop",),
    "electronic": ("electronic", "house", "techno", "ambient", "synth", "trip hop", "idm", "downtempo"),
    "dance": ("dance", "disco", "edm", "eurodance"),
    "hiphop": ("hip hop", "rap", "trap"),
    "rnb": ("r&b", "rnb", "neo soul"),
    "soul": ("soul", "funk", "motown", "blues"),
    "jazz": ("jazz", "bossa", "swing", "bebop"),
    "classical": ("classical", "baroque", "opera", "orchestral", "chamber"),
    "metal": ("metal",),
    "country": ("country", "americana", "bluegrass"),
    "blues": ("blues",),
    "reggae": ("reggae", "dub", "ska"),
}

# Nálada -> žánry, které k ní sedí. Tvých interpretů v redakčních playlistech
# nálady bývá málo -- tohle je druhý (slabší) zdroj "tvých" skladeb.
_MOOD_GENRES: dict[str, tuple[str, ...]] = {
    "sleep": ("folk", "classical"),
    "focus": ("classical", "electronic", "jazz"),
    "chill": ("indie", "rnb", "soul", "jazz", "folk"),
    "workout": ("hiphop", "dance", "electronic", "rock", "metal"),
    "party": ("dance", "pop", "hiphop"),
    "feelgood": ("pop", "soul", "indie"),
    "romance": ("rnb", "soul", "folk"),
    "sad": ("folk", "indie"),
    "morning": ("folk", "jazz", "soul", "indie"),
    "roadtrip": ("rock", "indie", "folk"),
}

_CLASSIFY_BUDGET_BACKGROUND = 250
_CLASSIFY_BUDGET_PAGE = 25

_locks: dict[str, asyncio.Lock] = defaultdict(asyncio.Lock)
_VERSION = 2  # zvýšit při změně skládání -- dnešní mixy se postaví znovu


def _source(category_id: str) -> str:
    return f"personal:category-mix:{category_id}"


# --------------------------------------------------------------------------
# Žánry interpretů
# --------------------------------------------------------------------------


def _stored_shares(artist_ids: list[str]) -> dict[str, dict[str, float] | None]:
    """artist -> {kategorie: podíl}; `None` = ještě nezjišťováno."""
    out: dict[str, dict[str, float] | None] = {}
    with Session(engine) as session:
        for artist_id in artist_ids:
            artist = session.get(Artist, artist_id)
            info = ((artist.external_refs or {}) if artist else {}).get("dzGenres")
            out[artist_id] = None if info is None else {k: float(v) for k, v in (info.get("shares") or {}).items()}
    return out


def _store_shares(artist_id: str, dz_id: str | None, shares: dict[str, float]) -> None:
    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None:
            return
        refs = dict(artist.external_refs or {})
        refs["dzGenres"] = {"dz": dz_id, "shares": shares}
        artist.external_refs = refs  # nová instance -- JSON sloupec nesleduje změny uvnitř
        session.add(artist)
        session.commit()


async def _classify(taste: pm.Taste, artist_id: str) -> dict[str, float]:
    dz_id = await pm._deezer_id(taste, artist_id)
    shares: dict[str, float] = {}
    if dz_id:
        albums = await get_deezer_client().artist_albums(dz_id)
        if albums is None:
            return {}  # Deezer nedostupný -- neukládat, zkusí se příště
        counts = Counter(_DZ_TO_CAT.get(a.get("genre_id")) for a in albums if (a.get("genre_id") or -1) > 0)
        total = sum(counts.values())
        if total:
            shares = {cat: round(n / total, 3) for cat, n in counts.items() if cat}
    await asyncio.to_thread(_store_shares, artist_id, dz_id, shares)
    return shares


def _mb_shares(taste: pm.Taste) -> dict[str, dict[str, float]]:
    """Záloha z MusicBrainz žánrů alb tvých skladeb."""
    per_artist: dict[str, Counter] = defaultdict(Counter)
    for recording_id, genres in taste.release_genres.items():
        artist_id = taste.artist_of.get(recording_id)
        if not artist_id:
            continue
        cats = {cat for genre in genres[:4] for cat, words in _MB_KEYWORDS.items() if any(w in genre.lower() for w in words)}
        for cat in cats:
            per_artist[artist_id][cat] += 1
    out = {}
    for artist_id, counts in per_artist.items():
        top = max(counts.values())
        out[artist_id] = {cat: n / top for cat, n in counts.items()}
    return out


async def artist_shares(taste: pm.Taste, budget: int) -> dict[str, dict[str, float]]:
    ranked = [a for a, _ in taste.artist_weight.most_common()]
    stored = await asyncio.to_thread(_stored_shares, ranked)
    classified = 0
    for artist_id in ranked:
        if classified >= budget:
            break
        if stored.get(artist_id) is None:
            stored[artist_id] = await _classify(taste, artist_id)
            classified += 1
            await asyncio.sleep(0.05)
    mb = _mb_shares(taste)
    # Štítky Last.fm (cache týden): Deezer nezná bluegrass ani podžánry,
    # štítky posluchačů ano -- interpret patří do žánru podle silnějšího.
    from app.home import lastfm_taste as lt

    lf: dict[str, dict[str, float]] = {}
    for artist_id in ranked[: max(budget * 4, 150)]:
        if is_own_artist(artist_id):
            # Štítky podle jména by patřily cizí kapele -- jen ručně zadané styly.
            from app.catalog.identity import own_styles

            manual = await asyncio.to_thread(own_styles, artist_id)
            if manual:
                lf[artist_id] = lt.shares_from_tags(manual)
            continue
        lf[artist_id] = await lt.tag_category_shares(taste.artist_name.get(artist_id, ""))
    out: dict[str, dict[str, float]] = {}
    for artist_id in ranked:
        shares = lt.merge_shares(stored.get(artist_id) or mb.get(artist_id) or {}, lf.get(artist_id) or {})
        if shares:
            out[artist_id] = shares
    if classified:
        logger.info("category mixes: zařazeno %d interpretů do žánrů", classified)
    return out


def genre_scores(taste: pm.Taste, shares: dict[str, dict[str, float]]) -> Counter:
    scores: Counter = Counter()
    for artist_id, weight in taste.artist_weight.items():
        for cat, share in (shares.get(artist_id) or {}).items():
            scores[cat] += weight * share
    return scores


# --------------------------------------------------------------------------
# Skladby
# --------------------------------------------------------------------------


def _familiar(taste: pm.Taste, artists: dict[str, float], rng: random.Random) -> list[str]:
    """Tvoje skladby od interpretů kategorie -- oblíbené/hrané napřed."""
    liked_or_played = set(taste.liked) | set(taste.listen_counts)
    preferred = [r for r in liked_or_played if taste.artist_of.get(r) in artists]
    fallback = [r for r in taste.library if taste.artist_of.get(r) in artists and r not in liked_or_played]
    if taste.activation is not None:
        # v2: podle toho, jak moc skladba teď "žije" (jako Denní mixy).
        liked = set(taste.liked)
        preferred = pm._weighted_order(preferred, lambda r: taste.track_score(r) + (0.05 if r in liked else 0.0), rng)
    else:
        rng.shuffle(preferred)
    rng.shuffle(fallback)
    # Co už je dnes v jiném mixu, až na konec (jedna skladba = jeden mix).
    used = pm.used_today()
    ordered = pm.prefer_unused(preferred, used) + pm.prefer_unused(fallback, used)
    target = round(MIX_SIZE * FAMILIAR_SHARE)
    return pm._spread(pm._cap_per_artist(ordered, taste.artist_of, 4)[:target], taste.artist_of)


async def _genre_mix(c: Category, taste: pm.Taste, shares: dict[str, dict[str, float]], rng: random.Random) -> tuple[list[str], list[str], list[str]]:
    members = {a: s[c.id] for a, s in shares.items() if s.get(c.id, 0) >= MEMBER_SHARE}
    familiar = _familiar(taste, members, rng)
    # Nové: "rádio" nejposlouchanějších interpretů, kteří jsou v žánru hlavně.
    core = sorted((a for a, s in members.items() if s >= 0.5), key=lambda a: -taste.artist_weight[a])
    seeds = [taste.artist_deezer[a] for a in core[:4] if a in taste.artist_deezer]
    want = min(MIX_SIZE - len(familiar), max(6, round(len(familiar) * (1 - FAMILIAR_SHARE) / FAMILIAR_SHARE)))
    new = await pm._new_tracks_from(seeds, taste.known, rng, want) if seeds else []
    top_artists = sorted(members, key=lambda a: -taste.artist_weight[a])
    return familiar, new, top_artists


async def _related_sets(taste: pm.Taste, limit: int = 60) -> dict[str, set[str]]:
    out: dict[str, set[str]] = {}
    for artist_id, _ in taste.artist_weight.most_common(limit * 2):
        if len(out) >= limit:
            break
        dz = await pm._deezer_id(taste, artist_id)
        if dz is None:
            continue
        out[artist_id] = {str(r["id"]) for r in await pm._related(dz) if r.get("id")}
    return out


async def _mood_mix(
    c: Category, taste: pm.Taste, shares: dict[str, dict[str, float]], rng: random.Random
) -> tuple[list[str], list[str], list[str]]:
    dz = get_deezer_client()
    mood_tracks: list[dict[str, Any]] = []
    for playlist in (await _category_playlists(c))[:4]:
        mood_tracks.extend(await dz.playlist_tracks(playlist["deezerId"], 100) or [])
    mood_artists = Counter(str((t.get("artist") or {}).get("id") or "") for t in mood_tracks)
    mood_artists.pop("", None)

    related = await _related_sets(taste)
    members: dict[str, float] = {}
    for artist_id, rel in related.items():
        dz_id = taste.artist_deezer.get(artist_id)
        overlap = len(rel & set(mood_artists))
        if dz_id in mood_artists or overlap >= 3:
            members[artist_id] = 1.0
    # Interpreti ze žánrů, které k náladě sedí -- až po těch z playlistů.
    genres = _MOOD_GENRES.get(c.id, ())
    by_genre = {
        a: 0.5
        for a, s in shares.items()
        if a not in members and sum(s.get(x, 0) for x in genres) >= 0.5
    }
    familiar = _familiar(taste, members, rng)
    if len(familiar) < round(MIX_SIZE * FAMILIAR_SHARE):
        extra = [r for r in _familiar(taste, by_genre, rng) if r not in familiar]
        familiar = pm._spread(familiar + extra[: round(MIX_SIZE * FAMILIAR_SHARE) - len(familiar)], taste.artist_of)
        members |= by_genre

    # Nové: skladby z playlistů nálady od interpretů podobných tvým.
    near = set().union(*related.values()) if related else set()
    near |= {taste.artist_deezer[a] for a in members if a in taste.artist_deezer}
    close = [t for t in mood_tracks if str((t.get("artist") or {}).get("id")) in near and not pm._is_junk(t)]
    rng.shuffle(close)
    want = min(MIX_SIZE - len(familiar), max(6, round(len(familiar) * (1 - FAMILIAR_SHARE) / FAMILIAR_SHARE)))
    # Málo podobných -> doplnit ostatními skladbami nálady (pořád do nálady sedí).
    rest = [t for t in mood_tracks if t not in close and not pm._is_junk(t)]
    rng.shuffle(rest)
    ids = [r for r in await asyncio.to_thread(g._ingest_tracks, (close + rest)[: want * 3]) if r not in taste.known]
    artist_of = await asyncio.to_thread(pm._artists_of, ids)
    new = pm._cap_per_artist(ids, artist_of, 2)[:want]
    top_artists = sorted(members, key=lambda a: (-members[a], -taste.artist_weight[a]))
    return familiar, new, top_artists


async def _listen_later_fitting(c: Category, taste: pm.Taste, mix_artists: list[str]) -> list[str]:
    """Skladby z "Poslechnout později", které do kategorie sedí: interpret v
    žánru (u nálady v žánrech nálady) nebo přímo mezi interprety mixu."""
    candidates = await asyncio.to_thread(listen_later.mix_candidates, g.home_user())
    if not candidates:
        return []
    artist_ids = list(dict.fromkeys(a for _, a in candidates))
    stored = await asyncio.to_thread(_stored_shares, artist_ids)
    for artist_id in [a for a in artist_ids if stored.get(a) is None][:10]:
        with Session(engine) as session:
            artist = session.get(Artist, artist_id)
            if artist is None:
                continue
            taste.artist_name.setdefault(artist_id, artist.name)
            if artist.deezer_id:
                taste.artist_deezer.setdefault(artist_id, artist.deezer_id)
        stored[artist_id] = await _classify(taste, artist_id)
    genres = (c.id,) if c.group == "genre" else _MOOD_GENRES.get(c.id, ())
    in_mix = set(mix_artists)

    def fits(artist_id: str) -> bool:
        shares = stored.get(artist_id) or {}
        return artist_id in in_mix or sum(shares.get(x, 0) for x in genres) >= (MEMBER_SHARE if c.group == "genre" else 0.5)

    return [rid for rid, artist_id in candidates if fits(artist_id)]


def _section_for(category_id: str) -> str | None:
    """Jen žánry vybrané na Domů mají sekci -- ostatní mixy jsou vidět jen
    na stránce kategorie."""
    with Session(engine) as session:
        snapshot = g.load_snapshot(session, PICKS_KEY)
        picks = (snapshot.payload or {}).get("picks") if snapshot else None
    return SECTION if category_id in (picks or []) else None


async def build_category_mix(c: Category, taste: pm.Taste | None = None, shares: dict[str, dict[str, float]] | None = None) -> str | None:
    """Postaví (nebo vrátí dnešní) mix kategorie; `None` = na mix není dost
    tvých skladeb v téhle kategorii."""
    day = f"{pm._day_key()}:{_VERSION}"
    async with _locks[c.id]:
        with Session(engine) as session:
            snapshot = g.load_snapshot(session, f"{_source(c.id)}:state")
            state = snapshot.payload if snapshot else None
            if state and state.get("stamp") == day:
                return state.get("playlistId")

        taste = taste or await asyncio.to_thread(pm.load_taste, g.home_user())
        rng = random.Random(f"{day}:{c.id}")
        if shares is None:
            shares = await artist_shares(taste, _CLASSIFY_BUDGET_PAGE)
        if c.group == "genre":
            familiar, new, top_artists = await _genre_mix(c, taste, shares, rng)
        else:
            familiar, new, top_artists = await _mood_mix(c, taste, shares, rng)

        tracks = pm._interleave(familiar, new)
        tracks = listen_later.weave(tracks, await _listen_later_fitting(c, taste, top_artists))
        playlist_id = None
        if len(familiar) >= MIN_FAMILIAR and len(tracks) >= MIN_MIX_SIZE:
            names = [taste.artist_name[a] for a in top_artists[:2] if a in taste.artist_name]
            playlist_id = g._save_playlist(
                owner=g.home_user(),
                source=_source(c.id),
                title=f"Tvůj mix · {c.title}",
                description=(f"{', '.join(names)} a další" if names else "Podle toho, co posloucháš"),
                kind=PlaylistKind.PERSONAL_MIX,
                section=_section_for(c.id) or "category_mix",
                recording_ids=tracks,
                cover_urls=pm._artist_covers(taste, top_artists) or g._covers_for(tracks),
                ttl=g.DAILY_TTL,
            )
            logger.info("category mix %s: %d skladeb (%d známých, %d nových)", c.id, len(tracks), len(familiar), len(new))
        else:
            await asyncio.to_thread(pm._clear_playlists, g.home_user(), [_source(c.id)])
            logger.info("category mix %s: málo skladeb (%d známých, %d celkem)", c.id, len(familiar), len(tracks))
        g._save_snapshot(f"{_source(c.id)}:state", {"stamp": day, "playlistId": playlist_id})
        return playlist_id


# --------------------------------------------------------------------------
# Domů: "Tvoje žánry"
# --------------------------------------------------------------------------


def update_picks(scores: Counter, previous: list[str]) -> list[str]:
    """Stabilní výběr: nový žánr vystřídá nejméně poslouchaný z vybraných,
    až když ho předběhne o `REPLACE_MARGIN`."""
    genres = [c.id for c in CATEGORIES if c.group == "genre" and scores.get(c.id, 0) > 0]
    picks = [p for p in previous if p in genres]
    for cat in sorted(genres, key=lambda x: -scores[x]):
        if len(picks) >= HOME_PICKS:
            break
        if cat not in picks:
            picks.append(cat)
    while True:
        outside = [x for x in genres if x not in picks]
        if not outside or not picks:
            break
        challenger = max(outside, key=lambda x: scores[x])
        weakest = min(picks, key=lambda x: scores[x])
        if scores[challenger] <= scores[weakest] * REPLACE_MARGIN:
            break
        picks[picks.index(weakest)] = challenger
    return sorted(picks, key=lambda x: -scores[x])


def _set_sections(picks: list[str]) -> None:
    with Session(engine) as session:
        for c in CATEGORIES:
            playlist = session.exec(
                select(Playlist).where(Playlist.owner_user_id == g.home_user(), Playlist.source == _source(c.id))
            ).first()
            if playlist is None:
                continue
            playlist.section = SECTION if c.id in picks else "category_mix"
            session.add(playlist)
        session.commit()


async def build_home_category_mixes() -> int:
    """Generátor Domů (každou hodinu, interně jednou za den)."""
    day = f"{pm._day_key()}:{_VERSION}"
    with Session(engine) as session:
        snapshot = g.load_snapshot(session, PICKS_KEY)
        payload = (snapshot.payload or {}) if snapshot else {}
    if payload.get("stamp") == day:
        return len(payload.get("picks") or [])
    taste = await asyncio.to_thread(pm.load_taste, g.home_user())
    shares = await artist_shares(taste, _CLASSIFY_BUDGET_BACKGROUND)
    scores = genre_scores(taste, shares)
    picks = update_picks(scores, payload.get("picks") or [])
    g._save_snapshot(PICKS_KEY, {"stamp": day, "picks": picks, "scores": {k: round(v, 1) for k, v in scores.most_common()}})
    built = []
    for cat_id in picks:
        c = get_category(cat_id)
        if c is not None and await build_category_mix(c, taste, shares):
            built.append(cat_id)
    await asyncio.to_thread(_set_sections, picks)
    logger.info("category mixes: Tvoje žánry %s (skóre %s)", picks, dict(scores.most_common(6)))
    return len(built)


def picks_order() -> list[str]:
    with Session(engine) as session:
        snapshot = g.load_snapshot(session, PICKS_KEY)
        return list(((snapshot.payload or {}) if snapshot else {}).get("picks") or [])


def playlist_card(playlist_id: str) -> dict[str, Any] | None:
    from app.home.service import _card

    with Session(engine) as session:
        playlist = session.get(Playlist, playlist_id)
        if playlist is None:
            return None
        card = _card(session, playlist)
        if card.item_count == 0:
            return None
        return card.model_dump(mode="json", by_alias=True)
