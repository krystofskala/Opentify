"""Osobní mixy ve stylu Spotify -- bez čekání na ListenBrainz.

Chuť = oblíbené skladby (nejvyšší váha), poslechy z tabulky `Listen` (čím
čerstvější, tím víc) a knihovna (slabě). Rozšíření o novou hudbu je zdarma
přes Deezer (`/artist/{id}/radio`, `/related`, `/top`), vše přes stávající
Deezer ingest (deduplikace podle Deezer id/ISRC) + AntiAIFilter.

  - Denní mix 1-6: interpreti seskupení podle podobnosti (sdílení Deezer
    "related" interpreti), v každém ~70 % známých skladeb z dané skupiny a
    ~30 % nových podobných; nový každý den (hranice ve 4:00), v rámci dne
    deterministický.
  - Objevy týdne: 30 NOVÝCH skladeb (ne v knihovně, ne oblíbené, ne nedávno
    hrané) od interpretů podobných tvým nejposlouchanějším; každé pondělí.
  - Na opakování: nejhranější za posledních 30 dní (jen když je aspoň 10
    různých skladeb).
  - Návrat do minulosti: oblíbené/hrané skladby, které jsi 90+ dní neslyšel.
"""

from __future__ import annotations

import asyncio
import logging
import math
import os
import random
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlmodel import Session, select

from app import listen_later
from app.catalog.artwork import _names_match, primary_artist_name
from app.catalog.deezer import get_deezer_client
from app.catalog.identity import is_own_artist
from app.db import engine
from app.home import generators as g
from app.home import lastfm_taste as lt
from app.library.spotify_import import get_or_create_liked_songs_playlist
from app.models import Artist, Listen, MediaAsset, MediaAssetStatus, Playlist, PlaylistItem, PlaylistKind, Recording, Release
from app.utils import utcnow

logger = logging.getLogger(__name__)

try:
    from zoneinfo import ZoneInfo

    _TZ = ZoneInfo(os.environ.get("HOME_TIMEZONE", "Europe/Prague"))
except Exception:  # noqa: BLE001 - chybí tzdata -> UTC
    _TZ = timezone.utc

MAX_DAILY_MIXES = 6
DAILY_MIX_SIZE = 40
FAMILIAR_SHARE = 0.7
MIN_MIX_SIZE = 15
_TOP_ARTISTS = 30
_EXTRA_ARTISTS = 200
_JUNK = ("karaoke", "originally performed", "in the style of", "made famous by", "tribute to", "instrumental version")


def _day_key() -> str:
    """Den mixů začíná ve 4:00 místního času."""
    return (datetime.now(_TZ) - timedelta(hours=4)).date().isoformat()


def _week_key() -> str:
    year, week, _ = (datetime.now(_TZ) - timedelta(hours=4)).isocalendar()
    return f"{year}-W{week:02d}"


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


# --------------------------------------------------------------------------
# Chuť uživatele
# --------------------------------------------------------------------------


@dataclass
class Taste:
    liked: list[str] = field(default_factory=list)
    library: set[str] = field(default_factory=set)
    listen_counts: Counter = field(default_factory=Counter)
    last_played: dict[str, datetime] = field(default_factory=dict)
    recent_listens: Counter = field(default_factory=Counter)  # posledních 30 dní
    artist_of: dict[str, str] = field(default_factory=dict)  # recording -> artist
    artist_weight: Counter = field(default_factory=Counter)
    artist_name: dict[str, str] = field(default_factory=dict)
    artist_deezer: dict[str, str] = field(default_factory=dict)
    artist_photo: dict[str, str] = field(default_factory=dict)
    release_genres: dict[str, list[str]] = field(default_factory=dict)  # recording -> genres

    @property
    def known(self) -> set[str]:
        return set(self.liked) | self.library | set(self.listen_counts)


def load_taste(user_id: str) -> Taste:
    taste = Taste()
    now = utcnow()
    with Session(engine) as session:
        liked_pl = get_or_create_liked_songs_playlist(session, user_id)
        taste.liked = list(
            session.exec(
                select(PlaylistItem.recording_id).where(PlaylistItem.playlist_id == liked_pl.id).order_by(PlaylistItem.position)
            ).all()
        )
        taste.library = set(
            session.exec(
                select(MediaAsset.recording_id).where(
                    MediaAsset.status == MediaAssetStatus.AVAILABLE,
                    (MediaAsset.hidden_from_library.is_(None)) | (MediaAsset.hidden_from_library.is_(False)),  # type: ignore[union-attr]
                )
            ).all()
        )
        since = now - timedelta(days=365)
        listens = session.exec(select(Listen).where(Listen.user_id == user_id, Listen.played_at >= since)).all()
        if user_id != g.HOME_USER_ID:
            # Sdílená knihovna je stažená podle vkusu admina -- u jiného
            # profilu se počítá jen to, co sám poslouchal nebo lajkl (jinak
            # by prázdný profil dostal mixy podle cizího vkusu).
            own = set(taste.liked) | {listen.recording_id for listen in listens}
            taste.library &= own
        for listen in listens:
            played = _aware(listen.played_at)
            taste.listen_counts[listen.recording_id] += 1
            if listen.recording_id not in taste.last_played or played > taste.last_played[listen.recording_id]:
                taste.last_played[listen.recording_id] = played
            if now - played <= timedelta(days=30):
                taste.recent_listens[listen.recording_id] += 1

        # Nelíbení interpreti nesmí být semínkem mixů ani jejich obalem.
        from app.library.dislikes import disliked_artist_ids

        banned = disliked_artist_ids(session, user_id)
        for recording_id in taste.known:
            recording = session.get(Recording, recording_id)
            if recording is None or not recording.artist_id or recording.artist_id in banned:
                continue
            taste.artist_of[recording_id] = recording.artist_id
            if recording.release_id:
                release = session.get(Release, recording.release_id)
                if release is not None and release.genres:
                    taste.release_genres[recording_id] = release.genres

        liked_set = set(taste.liked)
        for recording_id, artist_id in taste.artist_of.items():
            weight = 0.0
            if recording_id in liked_set:
                weight += 3.0
            for _ in range(taste.listen_counts.get(recording_id, 0)):
                weight += 1.0
            if recording_id in taste.last_played:
                days = (now - taste.last_played[recording_id]).days
                weight += 2.0 * math.exp(-days / 30)
            if recording_id in taste.library:
                weight += 0.2
            taste.artist_weight[artist_id] += weight

        for artist_id in taste.artist_weight:
            artist = session.get(Artist, artist_id)
            if artist is None:
                continue
            taste.artist_name[artist_id] = artist.name
            if artist.deezer_id:
                taste.artist_deezer[artist_id] = artist.deezer_id
            if artist.images:
                taste.artist_photo[artist_id] = artist.images[0]
    return taste


async def _deezer_id(taste: Taste, artist_id: str) -> str | None:
    if artist_id in taste.artist_deezer:
        return taste.artist_deezer[artist_id]
    name = primary_artist_name(taste.artist_name.get(artist_id, ""))
    if not name:
        return None
    try:
        candidates = await get_deezer_client().search_artist(name, trust_name=False)
    except Exception:  # noqa: BLE001
        return None
    for candidate in candidates:
        if _names_match(candidate.get("name", ""), name):
            taste.artist_deezer[artist_id] = str(candidate["id"])
            return taste.artist_deezer[artist_id]
    return None


async def _related(dz_id: str) -> list[dict[str, Any]]:
    try:
        return await get_deezer_client().artist_related(dz_id, 25) or []
    except Exception:  # noqa: BLE001
        return []


# --------------------------------------------------------------------------
# Shlukování interpretů
# --------------------------------------------------------------------------


@dataclass
class Cluster:
    artists: list[str] = field(default_factory=list)  # naše artist id, podle váhy
    signature: set[str] = field(default_factory=set)  # deezer id interpretů + jejich related
    radio_seeds: list[str] = field(default_factory=list)  # deezer id


async def build_clusters(taste: Taste) -> list[Cluster]:
    top = [a for a, _ in taste.artist_weight.most_common(_TOP_ARTISTS * 2)]
    related: dict[str, set[str]] = {}
    for artist_id in top:
        if len(related) >= _TOP_ARTISTS:
            break
        dz = await _deezer_id(taste, artist_id)
        if dz is None:
            continue
        rel = await _related(dz)
        signature = {dz} | {str(r["id"]) for r in rel if r.get("id")}
        # + podobní podle posluchačů Last.fm (jako "lf:<jméno>") -- Deezer
        # "related" je u menších žánrů slabý.
        # Vlastní interpret jen podle jména -- Last.fm zná jen cizí kapelu.
        name = taste.artist_name.get(artist_id, "")
        if not is_own_artist(artist_id):
            signature |= {f"lf:{lt.norm(name)}"} | {f"lf:{lt.norm(n)}" for n, _m in await lt.similar_artist_names(name)}
        related[artist_id] = signature
        await asyncio.sleep(0.05)

    def similarity(a: set[str], b: set[str]) -> float:
        if not a or not b:
            return 0.0
        return len(a & b) / min(len(a), len(b))

    clusters: list[Cluster] = []
    for artist_id in top:
        signature = related.get(artist_id)
        if signature is None:
            continue
        scored = [(similarity(signature, c.signature), c) for c in clusters]
        best_score, best = max(scored, key=lambda x: x[0], default=(0.0, None))
        if best is not None and best_score >= 0.12:
            best.artists.append(artist_id)
            best.signature |= signature
            continue
        if len(clusters) < MAX_DAILY_MIXES:
            clusters.append(Cluster(artists=[artist_id], signature=set(signature), radio_seeds=[taste.artist_deezer[artist_id]]))
        elif best is not None and best_score >= 0.04:
            best.artists.append(artist_id)
            best.signature |= signature

    for cluster in clusters:
        cluster.radio_seeds = [taste.artist_deezer[a] for a in cluster.artists[:3] if a in taste.artist_deezer]

    # Ostatní interpreti (mimo top): do skupiny, jejíž "podpis" obsahuje
    # jejich Deezer id -- jen 1 dotaz na interpreta, výsledky hledání se
    # cachují den.
    assigned = {a for c in clusters for a in c.artists}
    extra = [a for a, _ in taste.artist_weight.most_common(_TOP_ARTISTS * 2 + _EXTRA_ARTISTS) if a not in assigned]
    for artist_id in extra:
        dz = await _deezer_id(taste, artist_id)
        if dz is None:
            continue
        lf_key = f"lf:{lt.norm(taste.artist_name.get(artist_id, ''))}"
        direct = next((c for c in clusters if dz in c.signature or lf_key in c.signature), None)
        if direct is not None:
            direct.artists.append(artist_id)
            continue
        # Nepřímo: sdílí se skupinou aspoň 2 "related" interprety (1 dotaz
        # navíc, cachuje se den).
        rel = {str(r["id"]) for r in await _related(dz) if r.get("id")}
        overlap = max(((len(rel & c.signature), c) for c in clusters), key=lambda x: x[0], default=(0, None))
        if overlap[1] is not None and overlap[0] >= 2:
            overlap[1].artists.append(artist_id)
    return clusters


# --------------------------------------------------------------------------
# Skladby
# --------------------------------------------------------------------------


def _is_junk(track: dict[str, Any]) -> bool:
    text = f"{track.get('title', '')} {(track.get('artist') or {}).get('name', '')}".lower()
    return any(marker in text for marker in _JUNK)


def _cap_per_artist(recording_ids: list[str], artist_of: dict[str, str], cap: int) -> list[str]:
    counts: Counter = Counter()
    out = []
    for recording_id in recording_ids:
        artist = artist_of.get(recording_id, recording_id)
        if counts[artist] >= cap:
            continue
        counts[artist] += 1
        out.append(recording_id)
    return out


def _artists_of(recording_ids: list[str]) -> dict[str, str]:
    with Session(engine) as session:
        out = {}
        for recording_id in recording_ids:
            recording = session.get(Recording, recording_id)
            if recording is not None and recording.artist_id:
                out[recording_id] = recording.artist_id
        return out


async def _new_tracks_from(seeds: list[str], exclude: set[str], rng: random.Random, want: int) -> list[str]:
    dz = get_deezer_client()
    raw: list[dict[str, Any]] = []
    for seed in seeds:
        try:
            raw.extend(await dz.artist_radio(seed) or [])
        except Exception:  # noqa: BLE001
            continue
        await asyncio.sleep(0.05)
    raw = [t for t in raw if not _is_junk(t)]
    rng.shuffle(raw)
    ids = [r for r in await asyncio.to_thread(g._ingest_tracks, raw) if r not in exclude]
    artist_of = await asyncio.to_thread(_artists_of, ids)
    return _cap_per_artist(ids, artist_of, 2)[:want]


def _spread(recording_ids: list[str], artist_of: dict[str, str]) -> list[str]:
    """Stejný interpret ne několikrát za sebou -- střídání po interpretech."""
    groups: dict[str, list[str]] = defaultdict(list)
    for recording_id in recording_ids:
        groups[artist_of.get(recording_id, recording_id)].append(recording_id)
    queues = list(groups.values())
    out: list[str] = []
    while queues:
        for queue in list(queues):
            out.append(queue.pop(0))
            if not queue:
                queues.remove(queue)
    return out


def _interleave(familiar: list[str], new: list[str]) -> list[str]:
    out, fi, ni = [], 0, 0
    while fi < len(familiar) or ni < len(new):
        for _ in range(2):
            if fi < len(familiar):
                out.append(familiar[fi])
                fi += 1
        if ni < len(new):
            out.append(new[ni])
            ni += 1
    return out


def _genre_label(taste: Taste, cluster: Cluster, familiar: list[str]) -> str | None:
    counts: Counter = Counter()
    for recording_id in familiar:
        for genre in taste.release_genres.get(recording_id, [])[:3]:
            counts[genre.lower()] += 1
    if not counts:
        return None
    genre, n = counts.most_common(1)[0]
    return genre if n >= 2 else None


def _artist_covers(taste: Taste, artists: list[str]) -> list[str]:
    return [taste.artist_photo[a] for a in artists if a in taste.artist_photo][:4]


def _clear_playlists(owner: str, sources: list[str]) -> None:
    """Skrýt mixy, které dnes nevznikly (méně skupin než včera) -- prázdný
    playlist se na Domů nezobrazí."""
    with Session(engine) as session:
        for source in sources:
            playlist = session.exec(select(Playlist).where(Playlist.owner_user_id == owner, Playlist.source == source)).first()
            if playlist is None:
                continue
            for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all():
                session.delete(item)
        session.commit()


# --------------------------------------------------------------------------
# Generátory
# --------------------------------------------------------------------------


def _listen_later_candidates(user_id: str) -> list[tuple[str, str, str | None]]:
    """(recording, artist, Deezer id interpreta) ze "Poslechnout později"."""
    out = []
    with Session(engine) as session:
        for rid, artist_id in listen_later.mix_candidates(user_id):
            artist = session.get(Artist, artist_id)
            refs = (artist.external_refs or {}) if artist else {}
            dz = (artist.deezer_id if artist else None) or (refs.get("dzGenres") or {}).get("dz")
            out.append((rid, artist_id, dz))
    return out


def _already_built(key: str, stamp: str) -> int | None:
    with Session(engine) as session:
        snapshot = g.load_snapshot(session, key)
        if snapshot is not None and (snapshot.payload or {}).get("stamp") == stamp:
            return int((snapshot.payload or {}).get("count") or 0)
    return None


async def build_daily_mixes() -> int:
    day = _day_key()
    done = _already_built("personal:daily-mixes", day)
    if done is not None:
        return done
    taste = await asyncio.to_thread(load_taste, g.home_user())
    if len(taste.known) < 20:
        raise RuntimeError("osobní mixy: málo dat o chuti (oblíbené/poslechy)")
    clusters = await build_clusters(taste)
    known = taste.known
    liked_or_played = set(taste.liked) | set(taste.listen_counts)
    later = await asyncio.to_thread(_listen_later_candidates, g.home_user())
    later_used: set[str] = set()
    built = 0
    for index, cluster in enumerate(clusters, start=1):
        rng = random.Random(f"{day}:{index}")
        cluster_artists = set(cluster.artists)
        preferred = [r for r in liked_or_played if taste.artist_of.get(r) in cluster_artists]
        fallback = [r for r in taste.library if taste.artist_of.get(r) in cluster_artists and r not in liked_or_played]
        rng.shuffle(preferred)
        rng.shuffle(fallback)
        familiar_target = round(DAILY_MIX_SIZE * FAMILIAR_SHARE)
        familiar = _cap_per_artist(preferred + fallback, taste.artist_of, 5)[:familiar_target]
        familiar = _spread(familiar, taste.artist_of)
        # Poměr ~70/30 drží i u menších skupin -- málo známých skladeb se
        # nezaplácne novými (dřív tak vznikaly mixy s 85 % neznámé hudby).
        new_target = min(DAILY_MIX_SIZE - len(familiar), max(6, round(len(familiar) * (1 - FAMILIAR_SHARE) / FAMILIAR_SHARE)))
        # Půlka nových z Last.fm (co posluchači pouštějí spolu s tvými
        # nejhranějšími ze skupiny), půlka z Deezer rádia interpretů.
        seed_tracks = sorted(
            (r for r in familiar if r in liked_or_played),
            key=lambda r: -(taste.listen_counts.get(r, 0) + (3 if r in set(taste.liked) else 0)),
        )[:4]
        from_lastfm = await lt.similar_track_ids(seed_tracks, known, rng, new_target // 2 + 1)
        new = from_lastfm + [
            r for r in await _new_tracks_from(cluster.radio_seeds, known | set(from_lastfm), rng, new_target)
            if r not in from_lastfm
        ][: new_target - len(from_lastfm)]
        tracks = _interleave(familiar, new)
        if len(tracks) < MIN_MIX_SIZE:
            continue
        # "Poslechnout později": pár skladeb, jejichž interpret do skupiny patří
        # (nebo je jí podobný podle Deezeru).
        fitting = [
            rid
            for rid, artist_id, dz_id in later
            if rid not in later_used and (artist_id in cluster_artists or (dz_id and dz_id in cluster.signature))
        ]
        tracks = listen_later.weave(tracks, fitting)
        later_used.update(fitting[:3])
        built += 1
        names = [taste.artist_name[a] for a in cluster.artists[:2] if a in taste.artist_name]
        genre = _genre_label(taste, cluster, familiar)
        description = f"{', '.join(names)} a další" + (f" · {genre}" if genre else "")
        g._save_playlist(
            owner=g.home_user(),
            source=f"personal:daily-mix:{built}",
            title=f"Denní mix {built}",
            description=description,
            kind=PlaylistKind.PERSONAL_MIX,
            section="mixes",
            recording_ids=tracks,
            cover_urls=_artist_covers(taste, cluster.artists) or g._covers_for(tracks),
            ttl=g.DAILY_TTL,
        )
        await g._preprovision(tracks[:1])
        logger.info(
            "home: Denní mix %d -- %d skladeb (%d známých, %d nových), %s",
            built, len(tracks), len(familiar), len(new), description,
        )
    if built == 0:
        raise RuntimeError("osobní mixy: žádná skupina nedala dost skladeb")
    await asyncio.to_thread(
        _clear_playlists, g.home_user(), [f"personal:daily-mix:{n}" for n in range(built + 1, MAX_DAILY_MIXES + 1)]
    )
    g._save_snapshot("personal:daily-mixes", {"stamp": day, "count": built})
    return built


async def build_discover_weekly() -> int:
    week = _week_key()
    done = _already_built("personal:discover-weekly", week)
    if done is not None:
        return done
    taste = await asyncio.to_thread(load_taste, g.home_user())
    rng = random.Random(f"discover:{week}")
    recent = {r for r, t in taste.last_played.items() if utcnow() - t <= timedelta(days=60)}
    exclude = taste.known | recent
    known_names = {primary_artist_name(n).casefold() for n in taste.artist_name.values()}
    known_dz = set(taste.artist_deezer.values())

    # Kandidáti = "related" interpreti tvých top interpretů, které neznáš;
    # čím víc tvých interpretů je doporučuje, tím výš.
    candidates: Counter = Counter()
    for artist_id, _ in taste.artist_weight.most_common(15):
        dz = await _deezer_id(taste, artist_id)
        if dz is None:
            continue
        for rel in await _related(dz):
            rid, name = str(rel.get("id") or ""), rel.get("name") or ""
            if not rid or rid in known_dz or primary_artist_name(name).casefold() in known_names:
                continue
            candidates[rid] += 1
        await asyncio.sleep(0.05)
    # + podobní podle posluchačů Last.fm (shoda váží; víc tvých interpretů =
    # výš), převedení na Deezer přes přesné jméno.
    lf_scores: Counter = Counter()
    for artist_id, _ in taste.artist_weight.most_common(15):
        if is_own_artist(artist_id):  # Last.fm by našel stejnojmennou cizí kapelu
            continue
        for name, match in await lt.similar_artist_names(taste.artist_name.get(artist_id, ""), 25):
            if primary_artist_name(name).casefold() not in known_names:
                lf_scores[name] += match
    dzc_lookup = get_deezer_client()
    for name, score in lf_scores.most_common(40):
        try:
            hits = await dzc_lookup.search_artist(name, limit=5)
        except Exception:  # noqa: BLE001
            continue
        hit = next((h for h in hits if _names_match(h.get("name", ""), name)), None)
        rid = str(hit["id"]) if hit and hit.get("id") else ""
        if rid and rid not in known_dz:
            candidates[rid] += 2 * score
    ranked = [rid for rid, _ in candidates.most_common(40)]
    tail = ranked[10:]
    rng.shuffle(tail)  # nejdoporučovanější napřed, zbytek každý týden jinak
    ranked = ranked[:10] + tail

    dzc = get_deezer_client()
    picked: list[str] = []
    for rid in ranked:
        if len(picked) >= 30:
            break
        try:
            top = await dzc.artist_top(rid, 5) or []
        except Exception:  # noqa: BLE001
            continue
        top = [t for t in top if not _is_junk(t)]
        ids = [r for r in await asyncio.to_thread(g._ingest_tracks, top) if r not in exclude and r not in picked]
        picked.extend(ids[: 2 if len(ranked) < 20 else 1])
        await asyncio.sleep(0.05)
    if len(picked) < 15:
        raise RuntimeError(f"objevy týdne: jen {len(picked)} nových skladeb")
    rng.shuffle(picked)
    g._save_playlist(
        owner=g.home_user(),
        source="personal:discover-weekly",
        title="Objevy týdne",
        description="Nová hudba od interpretů podobných těm, které posloucháš. Každé pondělí nová.",
        kind=PlaylistKind.PERSONAL_MIX,
        section="mixes",
        recording_ids=picked[:30],
        cover_urls=g._covers_for(picked),
        ttl=timedelta(days=7),
    )
    await g._preprovision(picked[:1])
    g._save_snapshot("personal:discover-weekly", {"stamp": week, "count": len(picked[:30])})
    return len(picked[:30])


async def build_on_repeat() -> int:
    taste = await asyncio.to_thread(load_taste, g.home_user())
    ranked = [r for r, _ in sorted(taste.recent_listens.items(), key=lambda kv: (-kv[1], -taste.last_played[kv[0]].timestamp()))]
    if len(ranked) < 10:
        await asyncio.to_thread(_clear_playlists, g.home_user(), ["personal:on-repeat"])
        return 0
    ids = ranked[:30]
    g._save_playlist(
        owner=g.home_user(),
        source="personal:on-repeat",
        title="Na opakování",
        description="Co teď posloucháš nejvíc (posledních 30 dní)",
        kind=PlaylistKind.PERSONAL_MIX,
        section="mixes",
        recording_ids=ids,
        cover_urls=g._covers_for(ids),
        ttl=timedelta(hours=6),
    )
    return len(ids)


async def build_throwback() -> int:
    day = _day_key()
    taste = await asyncio.to_thread(load_taste, g.home_user())
    now = utcnow()
    candidates = [
        r
        for r in dict.fromkeys(list(taste.liked) + list(taste.listen_counts))
        if r not in taste.last_played or now - taste.last_played[r] >= timedelta(days=90)
    ]
    # Přednost mají skladby, které jsi dřív opravdu hrál (mají historii).
    played_before = [r for r in candidates if r in taste.listen_counts]
    rest = [r for r in candidates if r not in taste.listen_counts]
    rng = random.Random(f"throwback:{day}")
    rng.shuffle(played_before)
    rng.shuffle(rest)
    ids = _cap_per_artist(played_before + rest, taste.artist_of, 2)[:30]
    if len(ids) < 10:
        await asyncio.to_thread(_clear_playlists, g.home_user(), ["personal:throwback"])
        return 0
    g._save_playlist(
        owner=g.home_user(),
        source="personal:throwback",
        title="Návrat do minulosti",
        description="Oblíbené skladby, které jsi přes 3 měsíce neslyšel",
        kind=PlaylistKind.PERSONAL_MIX,
        section="mixes",
        recording_ids=ids,
        cover_urls=g._covers_for(ids),
        ttl=g.DAILY_TTL,
    )
    return len(ids)



def styles_key(user_id: str) -> str:
    return f"styles:{user_id}"


async def build_styles() -> int:
    """"Tvé styly" na Domů: nejposlouchanější styly profilu (štítky Last.fm
    jeho interpretů vážené poslechy a oblíbenými) -> zkratky na stránky stylů."""
    from app.models import HomeSnapshot

    user_id = g.home_user()
    taste = await asyncio.to_thread(load_taste, user_id)
    # Podle toho, co posloucháš TEĎ: poslech před 2 týdny váží polovinu,
    # před měsícem čtvrtinu; oblíbené jen málo (jinak by vládl celý rok).
    now = utcnow()
    weight: Counter = Counter()
    liked = set(taste.liked)
    for rid, artist_id in taste.artist_of.items():
        w = 0.0
        if rid in taste.last_played:
            days = max(0.0, (now - taste.last_played[rid]).total_seconds() / 86400)
            w += (1 + taste.recent_listens.get(rid, 0)) * 0.5 ** (days / 14)
        w += 0.05 * taste.listen_counts.get(rid, 0)
        if rid in liked:
            w += 0.3
        if w:
            weight[artist_id] += w
    # Vlastní interpreti jen s ručně zadanými styly -- štítky Last.fm podle
    # jména by byly cizí kapely (Kontrast -> německé EBM, živě u táty).
    from app.catalog.identity import own_styles

    top: list[tuple[str, float]] = []
    manual: dict[str, list[str]] = {}
    for a, w in weight.most_common(60):
        if a not in taste.artist_name:
            continue
        if is_own_artist(a):
            styles_of = await asyncio.to_thread(own_styles, a)
            if not styles_of:
                continue
            manual[taste.artist_name[a]] = styles_of
        top.append((taste.artist_name[a], w))
    styles = await lt.user_styles_weighted(top, 60, manual)
    with Session(engine) as session:
        row = session.get(HomeSnapshot, styles_key(user_id)) or HomeSnapshot(key=styles_key(user_id))
        # Na Domů 20 nejsilnějších, celý seznam pro "tvé podžánry" u žánrů.
        row.payload = {"tags": styles[:20], "all": styles}
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    return len(styles[:20])


def popular_playlists_key(user_id: str) -> str:
    return f"popular_playlists:{user_id}"


async def build_popular_playlists() -> int:
    """"Populární playlisty pro tebe": pro tvé nejsilnější styly (viz
    build_styles) nejsledovanější playlisty z Deezeru -- redakční napřed, pak
    od lidí podle počtu fanoušků. Otevřou se až na klepnutí (převzetí do
    katalogu, `browse.open_deezer_playlist`)."""
    from app import browse
    from app.models import HomeSnapshot
    from app.tags import title_of

    user_id = g.home_user()
    with Session(engine) as session:
        snap = session.get(HomeSnapshot, styles_key(user_id))
        tags = list((snap.payload or {}).get("tags") or [])[:10] if snap else []
    items: list[dict] = []
    seen: set[str] = set()
    for tag in tags:
        try:
            found = await browse.search_playlists(tag, 4, popular=True)
        except Exception:  # noqa: BLE001 - jeden styl nesmí shodit celou sekci
            continue
        for p in found:
            if p["deezerId"] in seen:
                continue
            seen.add(p["deezerId"])
            items.append({**p, "style": title_of(tag)})
            break
    with Session(engine) as session:
        row = session.get(HomeSnapshot, popular_playlists_key(user_id)) or HomeSnapshot(key=popular_playlists_key(user_id))
        row.payload = {"items": items}
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    return len(items)
