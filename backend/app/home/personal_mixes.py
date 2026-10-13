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
from itertools import zip_longest
import math
import os
import random
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlmodel import Session, select

from app import listen_later
from app.catalog.artwork import primary_artist_name, same_artist_name
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
FAMILIAR_SHARE = 0.75  # 25 % nových (rešerše 7t; Spotify Daily Mix ~25 %)
MIN_MIX_SIZE = 15
# Strop skladeb jednoho interpreta v Denním mixu (12. 10.: dřív 5, mixy
# měly 11 interpretů na 31 skladeb, jeden interpret 7× i s novými).
DAILY_MIX_ARTIST_CAP = 3
# Paměť Denních mixů (13. 10.: ~70 % mixu bylo stejné jako včera). Skladba
# z mixu před `age` dny: váha × MIX_PER_SERVE ** (0,5 ** ((age-1)/poločas)),
# interpret slaběji; nová nabídnutá a nepuštěná se 7 dní nevrací, po dvou
# nabídnutích za 3 týdny vůbec.
MIX_SERVE_HALF_LIFE = 2.0
MIX_PER_SERVE = 0.25
MIX_MEMORY_DAYS = 7
MIX_RESURFACE = 5  # míst pro dlouho neslyšené oblíbené ze skupiny
MIX_FEATURED = 3  # hlavní interpreti dne -- obal, popis, semínka rádia
# "Kolik nového" (Pusť teď) platí i pro mixy: podíl známých skladeb.
MIX_FAMILIAR_SHARE = {"low": FAMILIAR_SHARE, "mid": 0.6, "high": 0.5}
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
    # Skladby z vlastních playlistů profilu (i společných, kde je členem) --
    # poskládaný playlist říká, co má rád (živě: tátův "Koza Band").
    playlisted: set[str] = field(default_factory=set)
    # Váha skladby z playlistů: malý ručně poskládaný playlist víc než velký
    # import (2 590 skladeb ze Spotify by jinak přebilo i poslechy).
    playlist_weight: dict[str, float] = field(default_factory=dict)
    # Přeskočené dvakrát po sobě (SkipStreak >= 2).
    skipped: set[str] = field(default_factory=set)
    # Nový model (TASTE_MODEL=v2, app/home/activation.py): celá historie ve
    # třech profilech. None = původní model (posledních 365 dní).
    activation: Any = None
    # V kolika různých dnech profil poslouchal (Denní mixy až od 3 dnů --
    # jeden večer neurčí vkus natrvalo).
    listen_days: int = 0

    def track_score(self, recording_id: str) -> float:
        """Jak moc skladba "žije" teď (v2): střední profil + půlka dlouhého."""
        act = self.activation
        if act is None:
            return float(self.listen_counts.get(recording_id, 0))
        return act.medium.get(recording_id, 0.0) + 0.5 * act.long.get(recording_id, 0.0)

    @property
    def known(self) -> set[str]:
        return (set(self.liked) | self.library | set(self.listen_counts) | self.playlisted) - self.skipped


LIBRARY_ARTIST_CAP = 8.0
PLAYLIST_ARTIST_CAP = 12.0


def taste_v2() -> bool:
    """Nový model vkusu (celá historie). Přepínač, ať jde vrátit jedním
    řádkem v .env: TASTE_MODEL=v2 / v1."""
    import os

    return os.environ.get("TASTE_MODEL", "v2").lower() == "v2"


def load_taste(user_id: str) -> Taste:
    """Vkus profilu přes sdílenou mezipaměť (app/home/taste_cache.py). Každý
    volající dostane vlastní kopie slovníků, do kterých se dopisuje (jména,
    Deezer id interpretů) -- sdílený objekt se tak nemění pod rukama."""
    from dataclasses import replace

    from app.home import taste_cache

    taste = taste_cache.get("taste", user_id, lambda: _load_taste(user_id))
    return replace(taste, artist_name=dict(taste.artist_name), artist_deezer=dict(taste.artist_deezer))


def _load_taste(user_id: str) -> Taste:
    taste = Taste()
    now = utcnow()
    with Session(engine) as session:
        liked_pl = get_or_create_liked_songs_playlist(session, user_id)
        taste.liked = list(
            session.exec(
                select(PlaylistItem.recording_id).where(PlaylistItem.playlist_id == liked_pl.id).order_by(PlaylistItem.position)
            ).all()
        )
        # Knihovna = co si profil SÁM přidal (LibraryEntry: "Přidat do
        # knihovny", lajk, stažení) + u admina jeho vlastní hudební složka.
        # Jen stažené na serveru (jiným profilem, dopředu do fronty) ne --
        # dřív se počítaly všechny soubory a admina to tlačilo k cizímu vkusu.
        from app.auth import ADMIN_ID
        from app.models import LibraryEntry, SkipStreak

        available = set(
            session.exec(
                select(MediaAsset.recording_id).where(
                    MediaAsset.status == MediaAssetStatus.AVAILABLE,
                    (MediaAsset.hidden_from_library.is_(None)) | (MediaAsset.hidden_from_library.is_(False)),  # type: ignore[union-attr]
                )
            ).all()
        )
        added = set(session.exec(select(LibraryEntry.recording_id).where(LibraryEntry.user_id == user_id)).all())
        if user_id == ADMIN_ID:
            added |= set(
                session.exec(
                    select(MediaAsset.recording_id).where(
                        MediaAsset.source_provider.in_(("local", "musicbrainz-local"))  # type: ignore[union-attr]
                    )
                ).all()
            )
        taste.library = added & available
        # Dvakrát po sobě přeskočené -- do mixů ne (jednou = jen nálada).
        # Po 90 dnech se přeskočení zapomene (vkus se mění, "teď ne" není navždy).
        taste.skipped = set(
            session.exec(
                select(SkipStreak.recording_id).where(
                    SkipStreak.user_id == user_id,
                    SkipStreak.streak >= 2,
                    SkipStreak.updated_at >= (now - timedelta(days=90)).replace(tzinfo=None),
                )
            ).all()
        )
        # + přeskočené ve Spotify / Apple v kontextu algoritmu (180 dní).
        from app.home.repetition import imported_skips

        taste.skipped |= imported_skips(user_id)
        from app.models import Playlist, PlaylistKind, PlaylistMember

        member_of = set(
            session.exec(select(PlaylistMember.playlist_id).where(PlaylistMember.user_id == user_id)).all()
        )
        own_playlists = [
            p.id
            for p in session.exec(select(Playlist).where(Playlist.kind == PlaylistKind.USER)).all()
            if (p.owner_user_id == user_id or p.id in member_of) and p.id != liked_pl.id
        ]
        if own_playlists:
            rows = session.exec(
                select(PlaylistItem.playlist_id, PlaylistItem.recording_id).where(PlaylistItem.playlist_id.in_(own_playlists))  # type: ignore[attr-defined]
            ).all()
            sizes = Counter(pid for pid, _ in rows)
            for pid, rid in rows:
                # Do ~30 skladeb plná váha, větší playlist úměrně méně na skladbu.
                share = min(1.0, 30 / sizes[pid])
                taste.playlist_weight[rid] = max(taste.playlist_weight.get(rid, 0.0), share)
            taste.playlisted = set(taste.playlist_weight)
        since = now - timedelta(days=365)
        from app.home.activation import excluded_sources

        from app.home.activation import taste_exclusions

        off = excluded_sources(user_id)  # zdroje vypnuté ze vkusu (Profil › Hudba)
        ex_recs, ex_playlists = taste_exclusions(user_id)  # "Nepočítat do vkusu"
        ex_paths = {f"/playlists/{p}" for p in ex_playlists}
        listens = [
            x for x in session.exec(select(Listen).where(Listen.user_id == user_id, Listen.played_at >= since)).all()
            if x.source not in off and x.recording_id not in ex_recs and (x.context or "").split("?")[0] not in ex_paths
        ]
        for listen in listens:
            played = _aware(listen.played_at)
            taste.listen_counts[listen.recording_id] += 1
            if listen.recording_id not in taste.last_played or played > taste.last_played[listen.recording_id]:
                taste.last_played[listen.recording_id] = played
            if now - played <= timedelta(days=30):
                taste.recent_listens[listen.recording_id] += 1
        if taste_v2():
            from app.home import activation as av

            # Celá historie: "známé" a "naposledy" ze všech poslechů, ne z roku.
            act = av.cached(user_id)
            taste.activation = act
            taste.listen_counts = Counter(act.total)
            taste.last_played = dict(act.last)

        # Nelíbení interpreti nesmí být semínkem mixů ani jejich obalem.
        from app.library.dislikes import disliked_artist_ids

        banned = disliked_artist_ids(session, user_id)
        # Dávkově po 500 -- dřív `session.get` na každou skladbu i album
        # (u admina ~85 tisíc dotazů, 27-45 s; audit výkonu 7. 10.).
        known = list(taste.known)
        rec_rows: dict[str, tuple[str | None, str | None]] = {}
        for i in range(0, len(known), _BATCH):
            for rid, aid, relid in session.exec(
                select(Recording.id, Recording.artist_id, Recording.release_id).where(
                    Recording.id.in_(known[i : i + _BATCH])  # type: ignore[attr-defined]
                )
            ).all():
                rec_rows[rid] = (aid, relid)
        release_ids = list({relid for _aid, relid in rec_rows.values() if relid})
        genres_of: dict[str, list] = {}
        for i in range(0, len(release_ids), _BATCH):
            for relid, genres in session.exec(
                select(Release.id, Release.genres).where(Release.id.in_(release_ids[i : i + _BATCH]))  # type: ignore[attr-defined]
            ).all():
                if genres:
                    genres_of[relid] = genres
        for recording_id in taste.known:
            artist_id, release_id = rec_rows.get(recording_id, (None, None))
            if not artist_id or artist_id in banned:
                continue
            taste.artist_of[recording_id] = artist_id
            if release_id and release_id in genres_of:
                taste.release_genres[recording_id] = genres_of[release_id]

        liked_set = set(taste.liked)
        library_count: Counter = Counter()
        playlist_sum: Counter = Counter()
        v2 = taste.activation is not None
        for recording_id, artist_id in taste.artist_of.items():
            weight = 0.0
            if recording_id in liked_set:
                weight += 3.0
            if not v2:
                for _ in range(taste.listen_counts.get(recording_id, 0)):
                    weight += 1.0
                if recording_id in taste.last_played:
                    days = (now - taste.last_played[recording_id]).days
                    weight += 2.0 * math.exp(-days / 30)
            playlist_sum[artist_id] += 1.5 * taste.playlist_weight.get(recording_id, 0.0)
            if recording_id in taste.library:
                library_count[artist_id] += 1
            taste.artist_weight[artist_id] += weight
        # Knihovna: výslovně přidané (a vlastní složka) -- za interpreta nejvýš
        # strop, ať celá diskografie ve složce (Dylan, Beatles) nepřebije
        # poslouchání.
        for artist_id, n in library_count.items():
            taste.artist_weight[artist_id] += min(float(n), LIBRARY_ARTIST_CAP)
        # Playlisty taky se stropem -- uložený "This Is Bob Dylan" (50 skladeb)
        # je jeden signál "mám ho rád", ne padesát poslechů.
        for artist_id, w in playlist_sum.items():
            taste.artist_weight[artist_id] += min(w, PLAYLIST_ARTIST_CAP)
        if v2:
            # Poslechy: podíl interpreta ve smíchaných profilech (celá historie
            # + měsíce + teď) × počet poslechů za rok, ať je to ve stejném
            # měřítku jako lajky (+3) a stropy knihovny/playlistů.
            from app.home import activation as av

            scale = max(50.0, float(len(listens)))
            for artist_id, share in taste.activation.blend(av.ARTIST_BLEND).items():
                if artist_id not in banned:
                    taste.artist_weight[artist_id] += share * scale
        # Mladý profil: trvalý vliv má jen interpret, ke kterému se sám
        # vrací (návraty z vlastní volby, algoritmus třetinou) nebo výslovná
        # volba (srdíčko, knihovna, playlist) -- activation.tentative_factors,
        # váhy z auditu 7. 10.
        from app.home import activation as av
        from app.home.feedback import deltas as _feedback

        manual = _feedback(user_id)
        taste.listen_days = len({_aware(listen.played_at).date() for listen in listens})
        if taste.activation is not None:
            taste.listen_days = max(taste.listen_days, taste.activation.listening_days())
        confirmed = av.explicit_artists(user_id)  # jedna definice výslovné volby
        if taste.activation is not None:
            day_stats = taste.activation.artist_days()  # ví i o algoritmu
        else:
            labels = av.algorithmic_labels(session, user_id)
            day_stats = av.artist_day_stats(
                (_aware(x.played_at), taste.artist_of.get(x.recording_id), av.is_algorithmic(x.source, labels))
                for x in listens
            )
        for artist_id, factor in av.tentative_factors(day_stats, confirmed, taste.listen_days).items():
            if artist_id in taste.artist_weight:
                taste.artist_weight[artist_id] *= factor
        # "Víc / míň takových": jednotka = dvacetina nejsilnějšího interpreta,
        # takže +15 je zřetelné, ale nepřebije celý vkus.
        if manual:
            unit = max(1.0, (max(taste.artist_weight.values(), default=20.0)) / 20)
            for artist_id, delta in manual.items():
                taste.artist_weight[artist_id] = max(0.0, taste.artist_weight[artist_id] + delta * unit)
        # Dvakrát po sobě přeskočené: interpret trochu ztratí.
        for recording_id in taste.skipped:
            recording = session.get(Recording, recording_id)
            if recording is not None and recording.artist_id in taste.artist_weight:
                taste.artist_weight[recording.artist_id] = max(0.0, taste.artist_weight[recording.artist_id] - 1.0)

        artist_ids = list(taste.artist_weight)
        artist_rows: dict[str, tuple] = {}
        for i in range(0, len(artist_ids), _BATCH):
            for aid, name, deezer_id, images in session.exec(
                select(Artist.id, Artist.name, Artist.deezer_id, Artist.images).where(
                    Artist.id.in_(artist_ids[i : i + _BATCH])  # type: ignore[attr-defined]
                )
            ).all():
                artist_rows[aid] = (name, deezer_id, images)
        for artist_id in taste.artist_weight:
            row = artist_rows.get(artist_id)
            if row is None:
                continue
            name, deezer_id, images = row
            taste.artist_name[artist_id] = name
            if deezer_id:
                taste.artist_deezer[artist_id] = deezer_id
            if images:
                taste.artist_photo[artist_id] = images[0]
    return taste


_BATCH = 500


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
        if same_artist_name(candidate.get("name", ""), name):
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
    top = [a for a, w in taste.artist_weight.most_common(_TOP_ARTISTS * 2) if w > 0]  # "míň" může vynulovat
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
    extra = [a for a, w in taste.artist_weight.most_common(_TOP_ARTISTS * 2 + _EXTRA_ARTISTS) if a not in assigned and w > 0]
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


def _drop_heard(taste: Taste, recording_ids: list[str]) -> list[str]:
    from app.catalog.availability import recording_artist_name
    from app.home.activation import track_key

    out = []
    with Session(engine) as session:
        for rid in recording_ids:
            rec = session.get(Recording, rid)
            if rec is None:
                continue
            if track_key(recording_artist_name(session, rec) or "", rec.title or "") in taste.activation.heard_keys:
                continue
            out.append(rid)
    return out


def _weighted_order(items: list[str], weight, rng: random.Random, sharpen: float = 2.0, floor: float = 0.03) -> list[str]:
    """Vážené pořadí bez opakování (Efraimidis–Spirakis: klíč u^(1/w)).

    `sharpen`: váha na druhou -- jinak dlouhý ocas (tisíce jednou puštěných
    skladeb) v součtu přebije pár oblíbených. Položky pod `floor` × max jdou
    až za ostatní (náhodně), aby se vůbec dostaly jen při nedostatku."""
    weights = {item: max(float(weight(item)), 0.0) for item in items}
    top = max(weights.values(), default=0.0)
    keyed, tail = [], []
    for item, w in weights.items():
        if top > 0 and w >= floor * top:
            keyed.append((rng.random() ** (1.0 / max((w / top) ** sharpen, 1e-9)), item))
        else:
            tail.append(item)
    keyed.sort(reverse=True)
    rng.shuffle(tail)
    return [item for _k, item in keyed] + tail


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
    # Žánr musí sedět na podstatnou část mixu -- dřív stačily 2 skladby z
    # jednoho alba ("abstract hip hop" u mixu twenty one pilots / Coldplay).
    with_genre = sum(1 for r in familiar if taste.release_genres.get(r))
    return genre if n >= 3 and n >= with_genre / 3 else None


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
    deliberate = set(taste.liked) | taste.library | taste.playlisted
    if len(taste.known) < 20 or (len(deliberate) < 20 and taste.listen_days < 3):
        # 20 skladeb z jednoho večera (zkoušení, pouštění pro někoho) ještě
        # není vkus -- mixy až z poslechů aspoň ve 3 dnech, nebo z 20
        # výslovně vybraných (srdíčka, knihovna, playlisty, import). Jejich
        # složení pak drží váhy interpretů (jen opakované návraty trvale).
        # Nový profil bez historie -- očekávaný stav, ne chyba (dřív to každou
        # hodinu v logu hlásilo "generátor selhal").
        logger.info("osobní mixy %s: zatím málo dat o chuti, přeskakuji", g.home_user()[:8])
        return 0
    clusters = await build_clusters(taste)
    clusters, scene_of_cluster = await _with_scenes(clusters, taste, day)
    known = taste.known
    liked_or_played = set(taste.liked) | set(taste.listen_counts)
    later = await asyncio.to_thread(_listen_later_candidates, g.home_user())
    # "Víc / míň takových" i při výběru skladeb ze skupiny (dřív jen váha
    # interpreta při tvorbě skupin -- audit 7. 10. po změnách, chyba 3).
    from app.home.feedback import deltas, fit_multiplier

    manual = deltas(g.home_user())

    def mood_mult(artist_id: str | None) -> float:
        return fit_multiplier(manual[artist_id]) if artist_id in manual else 1.0
    later_used: set[str] = set()
    used_today: set[str] = set()
    results: list[tuple[int, Cluster, list[str], str, list[str]]] = []
    memory = await asyncio.to_thread(_mix_memory, g.home_user(), day, taste)
    from app.home.play_now import discovery_level

    from app.home import ratio

    familiar_share = await asyncio.to_thread(
        ratio.familiar_share,
        MIX_FAMILIAR_SHARE.get(await asyncio.to_thread(discovery_level, g.home_user()), FAMILIAR_SHARE),
        g.home_user(),
    )
    act = taste.activation
    former = set(act.former_loves()[:300]) if act is not None else set()
    from app.home.caught import caught_tracks

    caught = await asyncio.to_thread(caught_tracks, g.home_user(), act) if act is not None else []
    liked_set = set(taste.liked)
    for index, cluster in _stable_numbers(clusters, _previous_groups()):
        rng = random.Random(f"{g.home_user()}:{day}:{index}")
        cluster_artists = set(cluster.artists)
        preferred = [r for r in liked_or_played if taste.artist_of.get(r) in cluster_artists]
        fallback = [r for r in taste.library if taste.artist_of.get(r) in cluster_artists and r not in liked_or_played]
        featured = _featured_artists(cluster, taste, memory, rng)
        if taste.activation is not None:
            # v2: známé podle toho, jak moc teď "žijí" (vážené losování --
            # oblíbené častěji, ale každý den jinak; jednou puštěné z 2014
            # skoro nikdy). Lajk bez poslechu dostane malou základní váhu.
            # 13. 10.: odmocnina místo druhé mocniny (dřív vyhrávaly pořád
            # tytéž) a paměť minulých dnů.
            def weight(r: str) -> float:
                a = taste.artist_of.get(r)
                w = (taste.track_score(r) + (0.05 if r in liked_set else 0.0)) ** 0.5
                return w * mood_mult(a) * memory.track_factor(r) * memory.artist_factor(a) * (1.3 if a in featured else 1.0)

            preferred = _weighted_order(preferred, weight, rng, sharpen=1.0)
            # Dlouho neslyšené oblíbené ze skupiny dopředu (návrat do minulosti).
            back = [r for r in preferred if r in former and memory.track_factor(r) > 0.5][:MIX_RESURFACE]
            preferred = back + [r for r in preferred if r not in back]
        else:
            rng.shuffle(preferred)
        rng.shuffle(fallback)
        familiar_target = round(DAILY_MIX_SIZE * familiar_share)
        familiar = _cap_per_artist(preferred + fallback, taste.artist_of, DAILY_MIX_ARTIST_CAP)[:familiar_target]
        familiar = _spread(familiar, taste.artist_of)
        # Plynulé navazování energie (P3) -- konec skladby k začátku další.
        from app.home import energy_flow

        from app.home.taste_bridge import artist_styles

        # + vzdálenost stylů (bod 4): v jedné skupině bývají i dost odlišné věci.
        styles = await artist_styles(list({taste.artist_of[r] for r in familiar if r in taste.artist_of}))
        familiar = await asyncio.to_thread(energy_flow.order, familiar, taste.artist_of, None, styles)
        # Poměr ~70/30, u menších skupin nejvýš půl na půl -- málo známých
        # skladeb se nezaplácne novými (dřív mixy s 85 % neznámé hudby), ale
        # se stropem 3 na interpreta se malá skupina nescvrkne na 19 skladeb.
        new_target = min(
            DAILY_MIX_SIZE - len(familiar),
            max(6, round(len(familiar) * (1 - familiar_share) / familiar_share), min(len(familiar), DAILY_MIX_SIZE - len(familiar))),
        )
        # Půlka nových z Last.fm (co posluchači pouštějí spolu s dnešními
        # známými -- semínka losovaná, dřív pořád tytéž 4 nejhranější), půlka
        # z Deezer rádia dnešních hlavních interpretů (dřív jen záloha).
        today_known = [r for r in familiar[:12] if r in liked_or_played]
        seed_tracks = rng.sample(today_known, min(4, len(today_known)))
        # Chycená skladba ze skupiny jako semínko (navázat na nový objev).
        hook = next((r for r in caught if taste.artist_of.get(r) in cluster_artists), None)
        if hook and hook not in seed_tracks:
            seed_tracks = [hook, *seed_tracks][:4]
        exclude_new = known | memory.offered_new
        from_lastfm = await lt.similar_track_ids(seed_tracks, exclude_new, rng, new_target // 2 + 2)
        radio_seeds = [d for d in [await _deezer_id(taste, a) for a in featured] if d] or cluster.radio_seeds
        from_radio = [
            r for r in await _new_tracks_from(radio_seeds, exclude_new | set(from_lastfm), rng, new_target * 2)
            if r not in from_lastfm
        ]
        new = [r for pair in zip_longest(from_lastfm, from_radio) for r in pair if r]
        from app.home import novelty

        new = await asyncio.to_thread(novelty.filter_new, g.home_user(), new, taste.activation)
        # Strop interpreta platí pro celý mix -- nové od interpreta, který už
        # má mezi známými 3 skladby, se nepřidají (dřív 3 známé + 2 nové).
        new_artist = await asyncio.to_thread(_artists_of, new)
        per_artist = Counter(taste.artist_of.get(r) for r in familiar)
        capped_new: list[str] = []
        for r in new:
            a = new_artist.get(r, r)
            if per_artist[a] >= DAILY_MIX_ARTIST_CAP:
                continue
            per_artist[a] += 1
            capped_new.append(r)
        new = capped_new[:new_target]
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
        rng.shuffle(fitting)  # dřív každý den tytéž tři
        tracks = listen_later.weave(tracks, fitting)
        later_used.update(fitting[:3])
        tracks = [r for r in tracks if r not in used_today]  # jedna skladba = jeden mix
        used_today.update(tracks)
        names = [taste.artist_name[a] for a in featured[:2] if a in taste.artist_name]
        scene = scene_of_cluster.get(id(cluster))
        if scene is not None:
            # Spící scéna: styl + kdy se naposledy poslouchala.
            label = (scene.label.split(",")[0].strip() or "").capitalize()
            description = " · ".join(
                x for x in (label, f"{', '.join(names)} a další", f"naposledy {scene.last_year}" if scene.last_year else "") if x
            )
        else:
            genre = _genre_label(taste, cluster, familiar)
            description = f"{', '.join(names)} a další" + (f" · {genre}" if genre else "")
        results.append((index, cluster, tracks, description, featured))
        logger.info(
            "home: Denní mix (skupina %d) -- %d skladeb (%d známých, %d nových), %s",
            index, len(tracks), len(familiar), len(new), description,
        )
    if not results:
        raise RuntimeError("osobní mixy: žádná skupina nedala dost skladeb")
    # Čísla bez děr, pořadí podle stálých čísel skupin (Denní mix 1 zůstává
    # tatáž hudba ze dne na den, i když se skupiny přepočítají).
    results.sort(key=lambda r: r[0])
    groups: dict[str, list[str]] = {}
    for built, (_idx, cluster, tracks, description, featured) in enumerate(results, start=1):
        groups[str(built)] = cluster.artists[:15]
        g._save_playlist(
            owner=g.home_user(),
            source=f"personal:daily-mix:{built}",
            title=f"Denní mix {built}",
            description=description,
            kind=PlaylistKind.PERSONAL_MIX,
            section="mixes",
            recording_ids=tracks,
            cover_urls=_artist_covers(taste, list(dict.fromkeys([*featured, *cluster.artists]))) or g._covers_for(tracks),
            ttl=g.DAILY_TTL,
        )
        await g._preprovision(tracks[:1])
    built = len(results)
    await asyncio.to_thread(
        _clear_playlists, g.home_user(), [f"personal:daily-mix:{n}" for n in range(built + 1, MAX_DAILY_MIXES + 1)]
    )
    g._save_snapshot("personal:daily-mixes", {"stamp": day, "count": built})
    g._save_snapshot("personal:daily-mix-groups", {"groups": groups})
    _mark_used(day, used_today)
    shown_scenes = [scene_of_cluster[id(c)].id for _i, c, _t, _d, _f in results if id(c) in scene_of_cluster]
    if shown_scenes:
        from app.home import scenes

        await asyncio.to_thread(scenes.mark_shown, g.home_user(), shown_scenes, day)
    try:  # měření opakování mezi dny (7m) -- jen zápis
        from app.home import mix_log

        await asyncio.to_thread(
            mix_log.record, g.home_user(), day, {str(n): tr for n, (_i, _c, tr, _d, _f) in enumerate(results, start=1)}
        )
    except Exception:  # noqa: BLE001
        logger.exception("záznam Denních mixů")
    return built


STABLE_MIXES = 3  # z toho, co se poslouchá teď; zbytek ze spících scén


async def _with_scenes(clusters: list[Cluster], taste: Taste, day: str) -> tuple[list[Cluster], dict[int, object]]:
    """3 stálé skupiny (teď) + až 3 spící scény z mapy scén, které se dlouho
    neukázaly (13. 10.: deset let historie se v mixech neprojevovalo). Bez
    mapy scén (malý profil, ještě nespočítaná) jako dřív."""
    from app.home import scenes

    try:
        smap = await asyncio.to_thread(scenes.load, g.home_user())
        shown = await asyncio.to_thread(scenes.shown_days, g.home_user())
    except Exception:  # noqa: BLE001
        logger.exception("mapa scén")
        return clusters, {}
    if not smap.scenes:
        return clusters, {}
    stable = clusters[:STABLE_MIXES]
    taken = {a for c in stable for a in c.artists[:15]}
    rng = random.Random(f"{g.home_user()}:{day}:scenes")
    # Doprovodné scény k běžící vlně (co profil hrál u dřívějších vln téže
    # scény, 13. 10.) napřed -- nejvýš 2, aspoň jedno místo zůstane spícím.
    by_id = smap.by_id()
    try:
        from app.home import kam_dal

        comp = [by_id[s] for s in await asyncio.to_thread(kam_dal.companions, g.home_user()) if s in by_id]
    except Exception:  # noqa: BLE001
        comp = []
    comp = [s for s in comp if not ({*s.artists[:15]} & taken)]
    first = rng.sample(comp, min(2, len(comp)))
    picked = first + [
        s for s in scenes.pick_dormant(
            smap, MAX_DAILY_MIXES - len(stable), rng, today=day, shown=shown,
            exclude_artists=taken | {a for s in first for a in s.artists[:15]},
        ) if s not in first
    ][: MAX_DAILY_MIXES - len(stable) - len(first)]
    out = list(stable)
    info: dict[int, object] = {}
    for scene in picked:
        radio = [d for d in [await _deezer_id(taste, a) for a in scene.artists[:3]] if d]
        cluster = Cluster(artists=[*scene.artists, *scene.tail], radio_seeds=radio)
        info[id(cluster)] = scene
        out.append(cluster)
    # Málo spících scén: doplnit dalšími skupinami jako dřív.
    out += clusters[STABLE_MIXES : STABLE_MIXES + MAX_DAILY_MIXES - len(out)]
    return out, info


@dataclass
class MixMemory:
    """Co Denní mixy nabídly v minulých dnech (z `mix_log`)."""

    track_exp: Counter = field(default_factory=Counter)
    artist_exp: Counter = field(default_factory=Counter)
    offered_new: set[str] = field(default_factory=set)  # nové nabídnuté a nepuštěné

    def track_factor(self, rid: str) -> float:
        return max(0.02, MIX_PER_SERVE ** self.track_exp.get(rid, 0.0))

    def artist_factor(self, artist_id: str | None) -> float:
        return max(0.3, 0.7 ** self.artist_exp.get(artist_id, 0.0)) if artist_id else 1.0


def _mix_memory(user_id: str, day: str, taste: Taste) -> MixMemory:
    from app.home import mix_log

    mem = MixMemory()
    days_offered: Counter = Counter()
    try:
        history = mix_log.recent(user_id, day)
    except Exception:  # noqa: BLE001 -- bez paměti jako dřív
        logger.exception("paměť Denních mixů")
        return mem
    known = taste.known
    for age, mixes in history:
        decay = 0.5 ** ((age - 1) / MIX_SERVE_HALF_LIFE)
        ids = {r for tracks in mixes.values() for r in tracks}
        for rid in ids:
            if rid not in known:
                days_offered[rid] += 1
                if age <= MIX_MEMORY_DAYS:
                    mem.offered_new.add(rid)
            if age > MIX_MEMORY_DAYS:
                continue
            mem.track_exp[rid] += decay
            a = taste.artist_of.get(rid)
            if a:
                mem.artist_exp[a] += decay / 3
    mem.offered_new |= {r for r, n in days_offered.items() if n >= 2}
    return mem


def _featured_artists(cluster: Cluster, taste: Taste, memory: MixMemory, rng: random.Random) -> list[str]:
    """Hlavní interpreti dne ve stálé skupině: losovaní podle váhy, kdo byl
    hlavní nedávno, má menší šanci -- obal, popis i rádio se den ode dne mění,
    skupina (a číslo mixu) zůstává."""
    keyed = []
    for a in cluster.artists[:12]:
        w = max(taste.artist_weight.get(a, 0.0), 1e-6) ** 0.5 * memory.artist_factor(a) ** 2
        keyed.append((rng.random() ** (1.0 / w), a))
    keyed.sort(reverse=True)
    return [a for _k, a in keyed[:MIX_FEATURED]]


def _previous_groups() -> dict[int, list[str]]:
    """Interpreti včerejších Denních mixů podle čísla (pro stálá čísla)."""
    with Session(engine) as session:
        snap = g.load_snapshot(session, "personal:daily-mix-groups")
    raw = ((snap.payload or {}).get("groups") or {}) if snap else {}
    return {int(k): list(v) for k, v in raw.items() if str(k).isdigit()}


def _stable_numbers(clusters: list[Cluster], previous: dict[int, list[str]]) -> list[tuple[int, Cluster]]:
    """Každé skupině číslo včerejšího mixu, se kterým sdílí nejvíc hlavních
    interpretů (Jaccard >= 0,25); ostatní dostanou nejnižší volná čísla.
    Dřív se skupiny číslovaly podle pořadí a "Denní mix 1" byl každý den jiná
    hudba (plán P1, stabilní identita mixů)."""
    pairs = []
    for ci, cluster in enumerate(clusters):
        top = set(cluster.artists[:15])
        for n, artists in previous.items():
            prev = set(artists)
            union = top | prev
            score = len(top & prev) / len(union) if union else 0.0
            if score >= 0.25:
                pairs.append((score, ci, n))
    pairs.sort(reverse=True)
    assigned: dict[int, int] = {}
    taken: set[int] = set()
    for _score, ci, n in pairs:
        if ci not in assigned and n not in taken:
            assigned[ci] = n
            taken.add(n)
    free = (n for n in range(1, MAX_DAILY_MIXES + len(clusters) + 1) if n not in taken)
    for ci in range(len(clusters)):
        if ci not in assigned:
            assigned[ci] = next(free)
    return sorted(((assigned[ci], c) for ci, c in enumerate(clusters)), key=lambda x: x[0])


def _used_key(day: str) -> str:
    return f"mix-used:{day}"


def _mark_used(day: str, ids: set[str]) -> None:
    """Skladby, které už dnes jsou v některém mixu (jedna skladba = jeden mix)."""
    with Session(engine) as session:
        snap = g.load_snapshot(session, _used_key(day))
        have = set((snap.payload or {}).get("ids") or []) if snap else set()
    g._save_snapshot(_used_key(day), {"ids": sorted(have | ids)})


def used_today() -> set[str]:
    with Session(engine) as session:
        snap = g.load_snapshot(session, _used_key(_day_key()))
    return set((snap.payload or {}).get("ids") or []) if snap else set()


def prefer_unused(recording_ids: list[str], used: set[str]) -> list[str]:
    """Nejdřív skladby, které dnes ještě v žádném mixu nejsou; použité až
    jako záloha (malá knihovna -- mix nesmí zmizet)."""
    return [r for r in recording_ids if r not in used] + [r for r in recording_ids if r in used]


def _transient_seeds(taste: Taste, n: int) -> list[str]:
    """Interpreti, ze kterých jdou Objevy týdne: DOČASNÝ vkus -- co posloucháš
    teď (poslední týdny, vlastní volba i algoritmus), ne trvalý. Sestaví se
    tedy i z jednoho poslechu, ale příští týden už jdou podle toho, co hrálo
    pak (opentify-notes/skladani-hudby-navrh-2026-10-07.md). Výslovné volby
    (srdíčko, "víc takových") a trvalý vkus jako menší příměs."""
    act = taste.activation
    if act is None:
        return [a for a, w in taste.artist_weight.most_common(n) if w > 0]
    from app.home.activation import ARTIST_BLEND

    now = act.blend({"short": 0.75, "medium": 0.25})
    lasting = act.blend(ARTIST_BLEND)
    total_w = sum(taste.artist_weight.values()) or 1.0
    score: Counter = Counter()
    for a, v in now.items():
        score[a] += v
    for a, v in lasting.items():
        score[a] += 0.2 * v
    for a, w in taste.artist_weight.items():
        score[a] += 0.1 * w / total_w
    from app.home.feedback import deltas, fit_multiplier

    muted = {a for a, d in deltas(g.home_user()).items() if fit_multiplier(d) < 1}
    return [a for a, _s in score.most_common(n * 2) if taste.artist_weight.get(a, 0) > 0 and a not in muted][:n]


DISCOVER_MIN = 8  # menší Objevy jsou pořád lepší než žádné (dřív 15 a výjimka)


def _scene_seeds(user_id: str, rng: random.Random, skip: set[str], n: int) -> list[str]:
    """Semínka Objevů z `n` různých scén celé historie (i spících), losovaných
    podle váhy -- noví interpreti z celé šíře vkusu, ne jen z letoška."""
    from app.home import scenes

    try:
        smap = scenes.load(user_id)
    except Exception:  # noqa: BLE001
        return []
    keyed = sorted(
        ((rng.random() ** (1.0 / max(sc.weight ** 0.6, 1e-9)), sc) for sc in smap.scenes if sc.artists),
        key=lambda x: x[0], reverse=True,
    )
    out = []
    for _k, sc in keyed:
        pool = [a for a in sc.artists[:8] if a not in skip]
        if pool:
            out.append(rng.choice(pool))
        if len(out) >= n:
            break
    return out


async def _artist_of_rec(recording_id: str) -> str | None:
    from app.models import Recording

    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
    return rec.artist_id if rec else None


async def _in_scene_blocks(user_id: str, picked: list[str], track_seed: dict[str, str], rng: random.Random) -> list[str]:
    """Objevy v blocích podle scény, ze které vzešly (13. 10.: pop-punk,
    pak jazzová zpěvačka, pak zase pop-punk -- dřív se vše zamíchalo).
    Plynule: bloky za sebou podle podobnosti stylů (štítky Last.fm všech
    interpretů bloku), uvnitř bloku řetěz od skladby nejbližší konci
    předchozího bloku -- přechod jde přes to, co mají scény společné."""
    from app.home import scenes
    from app.home.extra_sections import _artist_names

    try:
        smap = scenes.load(user_id)
    except Exception:  # noqa: BLE001
        smap = scenes.SceneMap([])
    scene_of: dict[str, scenes.Scene] = {}
    for sc in smap.scenes:
        for a in [*sc.artists, *sc.tail]:
            scene_of.setdefault(a, sc)
    blocks: dict[str, list[str]] = {}
    for t in picked:
        sc = scene_of.get(track_seed.get(t, ""))
        blocks.setdefault(sc.id if sc else f"seed:{track_seed.get(t, '')}", []).append(t)
    names = await asyncio.to_thread(_artist_names, picked)
    tag_cache: dict[str, list[str]] = {}
    vec: dict[str, Counter] = {}
    for t in picked:
        name = names.get(t, "")
        if name and name not in tag_cache:
            try:
                tag_cache[name] = (await lt.artist_tags(name))[:6]
            except Exception:  # noqa: BLE001 -- bez štítků jen bloky
                tag_cache[name] = []
        vec[t] = Counter({tag: 1.0 / (1 + i) for i, tag in enumerate(tag_cache.get(name, []))})

    def sim(x: Counter, y: Counter) -> float:
        dot = sum(v * y.get(k, 0.0) for k, v in x.items())
        nx = sum(v * v for v in x.values()) ** 0.5
        ny = sum(v * v for v in y.values()) ** 0.5
        return dot / (nx * ny) if nx and ny else 0.0

    block_vec = {k: sum((vec[t] for t in ts), Counter()) for k, ts in blocks.items()}
    # Pořadí bloků: hladově z každého možného začátku, pak 2-opt (obrácení
    # úseků) -- dřív jen hladově od největšího bloku a na konec zbyly bloky,
    # které se k ničemu nehodily (bossa nova -> pop-punk -> klasická kytara).
    keys = list(blocks)
    rng.shuffle(keys)
    S = {(x, y): sim(block_vec[x], block_vec[y]) for x in keys for y in keys if x != y}

    def total(seq: list[str]) -> float:
        return sum(S[(x, y)] for x, y in zip(seq, seq[1:]))

    best: list[str] = keys[:1]
    for start in keys:
        left = [k for k in keys if k != start]
        seq = [start]
        while left:
            nxt = max(left, key=lambda k: S[(seq[-1], k)])
            left.remove(nxt)
            seq.append(nxt)
        if len(best) < len(seq) or total(seq) > total(best):
            best = seq
    improved = True
    while improved and len(best) > 3:
        improved = False
        for i in range(len(best) - 1):
            for j in range(i + 2, len(best) + 1):
                cand = best[:i] + best[i:j][::-1] + best[j:]
                if total(cand) > total(best) + 1e-9:
                    best, improved = cand, True
    order = best
    out: list[str] = []
    for i, k in enumerate(order):
        rest = list(blocks[k])
        rng.shuffle(rest)
        towards = block_vec[order[i + 1]] if i + 1 < len(order) else None
        # Poslední místo bloku = skladba nejbližší dalšímu bloku.
        last = max(rest, key=lambda t: sim(vec[t], towards)) if towards is not None and len(rest) > 1 else None
        if last is not None:
            rest.remove(last)
        while rest:
            prev = vec[out[-1]] if out else Counter()
            t = max(rest, key=lambda r: sim(prev, vec[r])) if out else rest[0]
            rest.remove(t)
            out.append(t)
        if last is not None:
            out.append(last)
    return out


def _discover_ignored(user_id: str) -> set[str]:
    """Skladby z minulých Objevů, které profil nepustil nebo přeskočil --
    znovu se nenabízejí (audit 13. 10.: Objevy si nabídnuté nepamatovaly).
    Pamatuje si posledních ~600."""
    from app.models import HomeSnapshot, PlayEvent, Playlist, PlaylistItem

    key = f"discover-ignored:{user_id}"
    with Session(engine) as session:
        row = session.get(HomeSnapshot, key)
        ignored = list((row.payload or {}).get("ids") or []) if row else []
        pl = session.exec(
            select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == "personal:discover-weekly")
        ).first()
        # Jen Objevy, které měly čas (přestavění v týdnu po změně algoritmu
        # by jinak "nepuštěné" označilo hned).
        if pl is not None and pl.updated_at and utcnow().replace(tzinfo=None) - pl.updated_at.replace(tzinfo=None) >= timedelta(days=5):
            ids = list(session.exec(select(PlaylistItem.recording_id).where(PlaylistItem.playlist_id == pl.id)).all())
            since = pl.updated_at
            played = set(session.exec(
                select(PlayEvent.recording_id).where(
                    PlayEvent.user_id == user_id, PlayEvent.recording_id.in_(ids),  # type: ignore[attr-defined]
                    PlayEvent.started_at >= since, PlayEvent.end_reason != "skipped",
                )
            ).all()) if ids else set()
            ignored = list(dict.fromkeys(ignored + [r for r in ids if r not in played]))[-600:]
            row = row or HomeSnapshot(key=key, payload={})
            row.payload = {"ids": ignored}
            row.generated_at = utcnow()
            session.add(row)
            session.commit()
    return set(ignored)


def _known_for_discover(taste: Taste) -> tuple[set[str], set[str]]:
    """Interpreti, které Objevy vynechají: jen ti, ke kterým se profil sám
    vrací (2+ dny, algoritmus po třetinách) nebo které si uložil. Dřív stačil
    jediný poslech kdykoli, celá sdílená složka i cizí playlisty -- u velké
    historie pak skoro každý podobný interpret byl "známý" (audit 13. 10.).
    Už slyšené SKLADBY dál hlídá `exclude` a `novelty.filter_new`."""
    keep: set[str] = set()
    act = taste.activation
    if act is not None:
        keep |= {a for a, (days, _span) in act.artist_days().items() if a and days >= 2}
    else:
        keep |= {a for a, w in taste.artist_weight.items() if w > 0}
    for rid in [*taste.liked, *taste.library]:
        a = taste.artist_of.get(rid)
        if a:
            keep.add(a)
    names = {primary_artist_name(taste.artist_name[a]).casefold() for a in keep if a in taste.artist_name}
    deezer = {taste.artist_deezer[a] for a in keep if a in taste.artist_deezer}
    return names, deezer


async def build_discover_weekly() -> int:
    week = _week_key()
    done = _already_built("personal:discover-weekly", week)
    if done is not None:
        return done
    taste = await asyncio.to_thread(load_taste, g.home_user())
    if not any(w > 0 for w in taste.artist_weight.values()):
        # Profil bez poslechů -- Objevy nemají z čeho vzniknout. Dřív to
        # v logu hlásilo "selhal" u každého nového profilu (7. 10.: 4×).
        return 0
    rng = random.Random(f"discover:{week}")
    recent = {r for r, t in taste.last_played.items() if utcnow() - t <= timedelta(days=60)}
    exclude = taste.known | recent | await asyncio.to_thread(_discover_ignored, g.home_user())
    known_names, known_dz = _known_for_discover(taste)
    # Semínka: dočasný vkus + interpreti z trvalého vkusu mimo něj (12. 10.:
    # jen z dočasného byly Objevy celé z jednoho žánrového rybníka).
    transient = _transient_seeds(taste, 10)
    lasting = _scene_seeds(g.home_user(), rng, set(transient), 8)
    if not lasting:
        lasting = [a for a, w in taste.artist_weight.most_common(60) if w > 0 and a not in transient]
        rng.shuffle(lasting)
    # Interpreti skladeb, které tě nedávno chytly, napřed (13. 10.).
    from app.home.caught import caught_tracks

    hooks = []
    if taste.activation is not None:
        for rid in await asyncio.to_thread(caught_tracks, g.home_user(), taste.activation):
            a = taste.artist_of.get(rid)
            if a and a not in hooks and a not in transient:
                hooks.append(a)
    seeds = list(dict.fromkeys(hooks[:4] + transient + lasting[:8]))
    try:
        from app.home import kam_dal

        share = await asyncio.to_thread(kam_dal.dose, g.home_user())
        if share > 0:
            tracks = await asyncio.to_thread(kam_dal.path_tracks, g.home_user(), ("vedle", "skok"))
            artists = [taste.artist_of.get(r) or _artist_of_rec(r) for r in tracks["vedle"][:6] + tracks["skok"][:6]]
            extra = [a for a in dict.fromkeys(artists) if a and a not in seeds][: max(1, round(len(seeds) * share / 2))]
            seeds = list(dict.fromkeys(seeds[: len(seeds) - len(extra) // 2] + extra))
    except Exception:  # noqa: BLE001 -- Kam dál je doplněk
        logger.exception("objevy týdne: kam dál")

    # Kandidáti = "related" interpreti tvých interpretů, které neznáš. Každé
    # semínko přispěje svými nejbližšími rovnoměrně (dřív vyhrávala shoda
    # víc semínek = vždy střed nejsilnějšího žánru).
    candidates: Counter = Counter()
    per_seed: list[list[str]] = []
    seed_of: dict[str, str] = {}  # kandidát -> semínko (bloky podle scény)
    for artist_id in seeds:
        dz = await _deezer_id(taste, artist_id)
        if dz is None:
            continue
        mine: list[str] = []
        for rel in await _related(dz):
            rid, name = str(rel.get("id") or ""), rel.get("name") or ""
            if not rid or rid in known_dz or primary_artist_name(name).casefold() in known_names:
                continue
            candidates[rid] += 1
            mine.append(rid)
            seed_of.setdefault(rid, artist_id)
        per_seed.append(mine)
        await asyncio.sleep(0.05)
    # + podobní podle posluchačů Last.fm (shoda váží; víc tvých interpretů =
    # výš), převedení na Deezer přes přesné jméno.
    lf_scores: Counter = Counter()
    lf_seed: dict[str, tuple[float, str]] = {}
    for artist_id in seeds:
        if is_own_artist(artist_id):  # Last.fm by našel stejnojmennou cizí kapelu
            continue
        for name, match in await lt.similar_artist_names(taste.artist_name.get(artist_id, ""), 25):
            if primary_artist_name(name).casefold() not in known_names:
                lf_scores[name] += match
                if match > lf_seed.get(name, (-1.0, ""))[0]:
                    lf_seed[name] = (match, artist_id)
    dzc_lookup = get_deezer_client()
    for name, score in lf_scores.most_common(40):
        try:
            hits = await dzc_lookup.search_artist(name, limit=5)
        except Exception:  # noqa: BLE001
            continue
        hit = next((h for h in hits if same_artist_name(h.get("name", ""), name)), None)
        rid = str(hit["id"]) if hit and hit.get("id") else ""
        if rid and rid not in known_dz:
            candidates[rid] += 2 * score
            seed_of.setdefault(rid, lf_seed[name][1])
    # Po kolech: z každého semínka jeho nejbližší dosud nevybraný (pořadí
    # semínek každý týden jinak), pak kandidáti Last.fm podle skóre.
    rng.shuffle(per_seed)
    ranked: list[str] = []
    for depth in range(4):
        for mine in per_seed:
            if depth < len(mine) and mine[depth] not in ranked:
                ranked.append(mine[depth])
    for rid, _ in candidates.most_common(60):
        if rid not in ranked:
            ranked.append(rid)
    ranked = ranked[:60]
    if not ranked:
        # Není z čeho (13. 10.: profil s jedinou vlastní skladbou hlásil
        # "selhal" každou hodinu celý týden) -- tiše nic.
        logger.info("objevy týdne: žádní kandidáti (semínek %d)", len(seeds))
        return 0

    dzc = get_deezer_client()
    picked: list[str] = []
    track_seed: dict[str, str] = {}
    for rid in ranked:
        if len(picked) >= 30:
            break
        try:
            top = await dzc.artist_top(rid, 5) or []
        except Exception:  # noqa: BLE001
            continue
        top = [t for t in top if not _is_junk(t)]
        ids = [r for r in await asyncio.to_thread(g._ingest_tracks, top) if r not in exclude and r not in picked]
        # Objevy = opravdu neslyšené (i pod jiným id) a bez nelíbí / míň /
        # přeskočených / pauzy -- společný filtr všech mixů (app/home/novelty.py).
        from app.home import novelty

        ids = await asyncio.to_thread(novelty.filter_new, g.home_user(), ids, taste.activation)
        for t in ids[: 2 if len(ranked) < 20 else 1]:
            picked.append(t)
            track_seed[t] = seed_of.get(rid, "")
        await asyncio.sleep(0.05)
    if len(picked) < 15:
        # Málo kandidátů: z každého víc skladeb (dřív výjimka a týden nic).
        from app.home import novelty

        for rid in ranked:
            if len(picked) >= 30:
                break
            try:
                top = await dzc.artist_top(rid, 5) or []
            except Exception:  # noqa: BLE001
                continue
            ids = [r for r in await asyncio.to_thread(g._ingest_tracks, [t for t in top if not _is_junk(t)])
                   if r not in exclude and r not in picked]
            ids = await asyncio.to_thread(novelty.filter_new, g.home_user(), ids, taste.activation)
            for t in ids[:3]:
                picked.append(t)
                track_seed[t] = seed_of.get(rid, "")
    logger.info("objevy týdne: semínek %d, kandidátů %d, vybráno %d", len(seeds), len(ranked), len(picked))
    if len(picked) < DISCOVER_MIN:
        raise RuntimeError(f"objevy týdne: jen {len(picked)} nových skladeb")
    picked = await _in_scene_blocks(g.home_user(), picked[:30], track_seed, rng)
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
    rng = random.Random(f"throwback:{day}")
    if taste.activation is not None:
        # v2: "bývalé lásky" -- skladby, které jsi kdysi opravdu hrál hodně
        # (≥ 4× za dva měsíce), teď ne; ne cokoli jednou puštěného. Z nejsilnějších
        # 150 každý den jiný výběr.
        loves = [r for r in taste.activation.former_loves() if r in taste.artist_of and r not in taste.skipped][:150]
        ordered = _weighted_order(loves, lambda r: taste.activation.peak.get(r, 1), rng)
        ordered = prefer_unused(ordered, await asyncio.to_thread(used_today))
        ids = _cap_per_artist(ordered, taste.artist_of, 2)[:30]
        await asyncio.to_thread(_mark_used, day, set(ids))
    else:
        candidates = [
            r
            for r in dict.fromkeys(list(taste.liked) + list(taste.listen_counts))
            if r not in taste.last_played or now - taste.last_played[r] >= timedelta(days=90)
        ]
        # Přednost mají skladby, které jsi dřív opravdu hrál (mají historii).
        played_before = [r for r in candidates if r in taste.listen_counts]
        rest = [r for r in candidates if r not in taste.listen_counts]
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
        w += 0.2 * taste.playlist_weight.get(rid, 0.0)
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
    import re
    import unicodedata

    def words(text: str) -> set[str]:
        text = unicodedata.normalize("NFKD", text.lower()).encode("ascii", "ignore").decode()
        return set(re.findall(r"[a-z0-9]+", text))

    items: list[dict] = []
    seen: set[str] = set()
    for tag in tags:
        try:
            found = await browse.search_playlists(tag, 8, popular=True)
        except Exception:  # noqa: BLE001 - jeden styl nesmí shodit celou sekci
            continue
        tag_words = words(tag)
        for p in found:
            if p["deezerId"] in seen:
                continue
            # Deezer hledá přibližně ("banjo" -> "Banho Relaxante") -- název
            # musí obsahovat slovo stylu, jinak radši další výsledek.
            if not tag_words & words(p.get("title") or ""):
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
