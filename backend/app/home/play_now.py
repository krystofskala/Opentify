"""Pusť teď a nekonečné hraní: další várka skladeb na jedno ťuknutí.

- **Pusť teď** (bez semínek): co profil obvykle pouští v tuhle denní dobu,
  vážené tím, jak moc skladby teď "žijí" (app/home/activation.py).
- **Nekonečné hraní** (semínka = co právě hrálo): navazuje na interprety
  semínek a na ty, které profil pouští ve stejných chvílích (podobnost z
  vlastní historie, ne z cizích dat).

Obojí ~80 % známé, ~20 % nové (Last.fm "posluchači pouštějí spolu").
Session řídí: interpret přeskočený v posledních 40 minutách jde stranou,
dvě přeskočení za sebou = změna směru (jiní interpreti než ti přeskočení).
Důvod se ukazuje jen pro celý výběr, ne u každé skladby.
"""

from __future__ import annotations

import asyncio
import functools
import random
import logging
import time
from collections import Counter
from datetime import timedelta
from typing import Any

from sqlmodel import Session, select

from app.db import engine
from app.home import activation as av
from app.models import Listen, PlayEvent, Recording, SkipStreak
from app.utils import utcnow

NEW_SHARE = 0.2
_CACHE_SECONDS = 600
logger = logging.getLogger(__name__)
# Strop interpreta pro celou relaci (návrh 1): každé zahrání v posledních
# `SESSION_WINDOW` skladbách fronty sníží šanci dalšího na `SESSION_DECAY`×.
SESSION_WINDOW = 30
SESSION_DECAY = 0.3
# Paměť posledních várek (návrh 4): nové ťuknutí nedá skoro to samé.
_BATCH_MEMORY = 3
_BATCH_TTL_S = 6 * 3600
RECENT_BATCH_PENALTY = 0.15
# Čistý start (kamarádi bez importu historie): pod tolik slyšených skladeb
# je profil "malý" -- známé i ze srdíček a knihovny, víc nového, semínka z
# různých interpretů, denní doba skoro nehraje roli, relace učí rychleji.
SMALL_PROFILE = 30
SMALL_NEW_SHARE = 0.5
TIME_SHRINK_K = 40  # poslechů, při kterých má denní doba poloviční váhu
_batches: dict[str, list[tuple[float, set[str]]]] = {}

# Čipy nálad (plán P2): nálada -> (kategorie z app/tags.SUBGENRES, štítky
# navíc, popisek). Nálada interpreta ze štítků Last.fm (cache týden) -- dokud
# nemáme rozbor zvuku (P4). "prekvap" = víc nového, bez denní doby.
MOODS: dict[str, tuple[str | None, tuple[str, ...], str]] = {
    "klid": ("chill", ("chill", "mellow", "relaxing", "calm", "acoustic", "ambient", "soft rock"), "Klid"),
    "energie": ("workout", ("energetic", "upbeat", "punk", "pop punk", "metal", "hard rock", "garage rock"), "Energie"),
    "soustredeni": ("focus", ("instrumental", "ambient", "post-rock", "classical", "piano", "jazz"), "Soustředění"),
    "melancholie": ("sad", ("sad", "melancholic", "melancholy", "mellow", "singer-songwriter", "slowcore"), "Melancholie"),
    "party": ("party", ("dance", "party", "upbeat", "funk", "disco", "pop"), "Párty"),
    "prekvap": (None, (), "Překvap mě"),
}


async def mood_fit(act: av.Activation, mood: str, limit: int = 80) -> dict[str, float]:
    """Interpret -> jak sedí na náladu (0..1) podle jeho štítků Last.fm."""
    from app.home import lastfm_taste as lt
    from app.models import Artist
    from app.tags import SUBGENRES

    category, extra, _label = MOODS[mood]
    terms = set(SUBGENRES.get(category or "", ())) | set(extra)
    top = [a for a, _ in act.blend(av.ARTIST_BLEND).most_common(limit)]
    with Session(engine) as session:
        names = {a: (session.get(Artist, a).name if session.get(Artist, a) else "") for a in top}
    sem = asyncio.Semaphore(8)

    async def one(artist_id: str) -> tuple[str, float]:
        async with sem:
            try:
                tags = [t.lower() for t in (await asyncio.wait_for(lt.artist_tags(names[artist_id]), 8))[:10]]
            except Exception:  # noqa: BLE001
                return artist_id, 0.0
        # Silnější štítky (dřív v seznamu) víc.
        score = sum(1.0 / (1 + i * 0.3) for i, t in enumerate(tags) if t in terms)
        return artist_id, min(1.0, score / 1.5)

    return dict(await asyncio.gather(*(one(a) for a in top if names.get(a))))
_cache: dict[str, tuple[float, av.Activation]] = {}


def _activation(user_id: str) -> av.Activation:
    hit = _cache.get(user_id)
    if hit and time.time() - hit[0] < _CACHE_SECONDS:
        return hit[1]
    act = av.compute(user_id)
    _cache[user_id] = (time.time(), act)
    return act


@functools.lru_cache(maxsize=200_000)
def _title_key(title: str) -> str:
    """Čistá funkce názvu -- v cache: `score()` ji volal ~100 tisíc× na várku
    (2,5 s z 3,3 s výběru, držela GIL a brzdila ostatní požadavky)."""
    from app.download_match import core_title, tokens

    return " ".join(tokens(core_title(title or "")))


def _recent_batch_ids(user_id: str) -> set[str]:
    now = time.time()
    keep = [(t, ids) for t, ids in _batches.get(user_id, []) if now - t < _BATCH_TTL_S]
    _batches[user_id] = keep
    mem = set().union(*(ids for _t, ids in keep)) if keep else set()
    # + z databáze (RecBatchItem): paměť přežije restart / nasazení.
    from app.home.repetition import recent_batch_ids

    try:
        return mem | recent_batch_ids(user_id, _BATCH_TTL_S / 3600, _BATCH_MEMORY)
    except Exception:  # noqa: BLE001
        return mem


def _remember_batch(user_id: str, ids: list[str]) -> None:
    keep = _batches.get(user_id, [])
    keep.append((time.time(), set(ids)))
    _batches[user_id] = keep[-_BATCH_MEMORY:]


def _artist_counts(recording_ids: list[str]) -> Counter:
    """Interpret -> kolikrát je v daných skladbách."""
    out: Counter = Counter()
    if not recording_ids:
        return out
    with Session(engine) as session:
        rows = session.exec(
            select(Recording.id, Recording.artist_id).where(Recording.id.in_(list(set(recording_ids))))  # type: ignore[attr-defined]
        ).all()
    artist_of = dict(rows)
    for rid in recording_ids:
        if artist_of.get(rid):
            out[artist_of[rid]] += 1
    return out


async def _band_links(artist_ids: list[str]) -> dict[str, set[str]]:
    """Sólo projekty a kapely (Tyler Joseph <-> twenty one pilots) podle vztahů
    z MusicBrainz -- jen z cache (bez dotazů ven); co cache nezná, nespojí."""
    import json

    from app.catalog.cache import CACHE_PREFIX
    from app.models import Artist
    from app.redis_bus import get_redis

    if not artist_ids:
        return {}
    with Session(engine) as session:
        mbids = {
            a.id: a.mbid
            for a in session.exec(select(Artist).where(Artist.id.in_(artist_ids))).all()  # type: ignore[attr-defined]
            if a.mbid and not a.mbid.startswith("own:")
        }
    if not mbids:
        return {}
    try:
        raws = await get_redis().mget([CACHE_PREFIX + f"mb:artist:{m}" for m in mbids.values()])
    except Exception:  # noqa: BLE001 -- bez Redisu bez spojování
        return {}
    related_mbids: dict[str, set[str]] = {}
    for aid, raw in zip(mbids, raws):
        if not raw:
            continue
        try:
            rels = (json.loads(raw) or {}).get("relations") or []
        except (ValueError, AttributeError):
            continue
        related_mbids[aid] = {
            (rel.get("artist") or {}).get("id")
            for rel in rels
            if rel.get("type") == "member of band" and (rel.get("artist") or {}).get("id")
        }
    wanted = set().union(*related_mbids.values()) if related_mbids else set()
    if not wanted:
        return {}
    with Session(engine) as session:
        by_mbid = {
            a.mbid: a.id
            for a in session.exec(select(Artist).where(Artist.mbid.in_(list(wanted)))).all()  # type: ignore[attr-defined]
        }
    return {aid: {by_mbid[m] for m in ms if m in by_mbid} for aid, ms in related_mbids.items()}


async def session_artist_counts(played: list[str]) -> Counter:
    """Kolikrát interpret (i přes svou kapelu / sólo projekt) hrál v
    posledních `SESSION_WINDOW` skladbách fronty."""
    counts = await asyncio.to_thread(_artist_counts, played[-SESSION_WINDOW:])
    links = await _band_links(list(counts))
    out = Counter(counts)
    for artist, related in links.items():
        for other in related:
            out[other] += counts[artist]
    return out


def _session_signals(session: Session, user_id: str) -> tuple[Counter, Counter, bool]:
    """(přeskočení interpreti, dohraní interpreti, změnit směr) za 40 minut.

    Přeskočení a "jiný směr" jen z toho, co pustil ALGORITMUS (Pusť teď,
    mix, rádio): proklikávání vlastního alba nebo playlistu je výběr, ne
    "nelíbí se" (audit 7. 10., mezera 3 -- dřív spustilo "Zkouším jiný
    směr"). Dohrání se počítá odkudkoli -- co teď posloucháš celé, sedí."""
    since = (utcnow() - timedelta(minutes=40)).replace(tzinfo=None)
    rows = session.exec(
        select(PlayEvent.recording_id, PlayEvent.end_reason, PlayEvent.algorithmic)
        .where(PlayEvent.user_id == user_id, PlayEvent.ended_at >= since)
        .order_by(PlayEvent.ended_at)
    ).all()
    skipped, done = Counter(), Counter()
    for rid, reason, algo in rows:
        rec = session.get(Recording, rid)
        if rec is None or not rec.artist_id:
            continue
        if reason == "skipped" and algo:
            skipped[rec.artist_id] += 1
        elif reason == "completed":
            done[rec.artist_id] += 1
    last_two = [r for _rid, r, algo in rows if algo][-2:]
    return skipped, done, len(last_two) == 2 and all(r == "skipped" for r in last_two)


def _clean_seeds(user_id: str, seeds: list[str]) -> list[str]:
    """Semínka nekonečného hraní bez přeskočených skladeb -- dřív se
    navazovalo i na to, co jsi právě přeskočil (audit 7. 10., mezera 3).
    Zůstane-li prázdné, aspoň poslední semínko (ať je na co navázat)."""
    if not seeds:
        return seeds
    since = (utcnow() - timedelta(hours=2)).replace(tzinfo=None)
    with Session(engine) as session:
        skipped = set(
            session.exec(
                select(PlayEvent.recording_id).where(
                    PlayEvent.user_id == user_id,
                    PlayEvent.ended_at >= since,
                    PlayEvent.end_reason == "skipped",
                    PlayEvent.recording_id.in_(seeds),  # type: ignore[attr-defined]
                )
            ).all()
        )
    kept = [r for r in seeds if r not in skipped]
    return kept or seeds[-1:]


def _chosen_tracks(session: Session, user_id: str, limit: int = 200) -> list[str]:
    """Srdíčka a knihovna (nejnovější první) -- co si člověk sám vybral."""
    from app.library.spotify_import import LIKED_SONGS_SOURCE
    from app.models import LibraryEntry, Playlist, PlaylistItem

    out: list[str] = []
    liked = session.exec(
        select(Playlist.id).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
    ).first()
    if liked:
        out += session.exec(
            select(PlaylistItem.recording_id)
            .where(PlaylistItem.playlist_id == liked)
            .order_by(PlaylistItem.position.desc())  # type: ignore[attr-defined]
            .limit(limit)
        ).all()
    try:
        out += session.exec(
            select(LibraryEntry.recording_id)
            .where(LibraryEntry.user_id == user_id, LibraryEntry.recording_id.is_not(None))  # type: ignore[union-attr]
            .limit(limit)
        ).all()
    except Exception:  # noqa: BLE001 -- knihovna jen jako doplněk
        pass
    return list(dict.fromkeys(r for r in out if r))


def _distinct_artist_seeds(pool: list[str], artist_of: dict[str, str], n: int) -> list[str]:
    missing = [r for r in pool if r not in artist_of]
    meta = _rec_meta(missing) if missing else {}
    out: list[str] = []
    seen: set[str] = set()
    for rid in pool:
        a = artist_of.get(rid) or (meta.get(rid) or (None, ""))[0]
        if not a or a in seen:
            continue
        seen.add(a)
        out.append(rid)
        if len(out) >= n:
            break
    return out


def pick(
    user_id: str, seeds: list[str], played: list[str], size: int, rng: random.Random,
    mood: str | None = None, moods: dict[str, float] | None = None, new_share: float = NEW_SHARE,
    session_counts: Counter | None = None, ctx: dict[str, Any] | None = None,
) -> tuple[list[str], list[str], str]:
    """Známé skladby + semínka pro nové. Vrací (známé, semínka_pro_nové, důvod).
    `session_counts`: interpreti z poslední části fronty (strop relace);
    `ctx` (je-li dané) dostane filtry pro nové skladby."""
    session_counts = session_counts or Counter()
    from app.home.quick_picks import time_profile
    from app.library.dislikes import disliked_artist_ids

    act = _activation(user_id)
    with Session(engine) as session:
        banned = disliked_artist_ids(session, user_id)
        skipped_artists, done_artists, turn = _session_signals(session, user_id)
        _ctx, time_artists, _recs = time_profile(session, user_id)
        recent_order = list(
            session.exec(
                select(Listen.recording_id)
                .where(Listen.user_id == user_id, Listen.played_at >= (utcnow() - timedelta(hours=3)).replace(tzinfo=None))
                .order_by(Listen.played_at.desc())  # type: ignore[attr-defined]
            ).all()
        )
        recent = set(recent_order)
        # Nový profil: všechno, co slyšel, je z posledních 3 h (a ta se
        # vynechávají) -- nové pak naváže aspoň na to a na lajky. Dřív
        # zůstalo Pusť teď prázdné i po prvních poslechech (UX audit 7. 10.).
        fallback_seeds = list(dict.fromkeys(recent_order))[:3]
        if not fallback_seeds:
            from app.library.spotify_import import LIKED_SONGS_SOURCE
            from app.models import Playlist, PlaylistItem

            liked = session.exec(
                select(Playlist.id).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
            ).first()
            if liked:
                fallback_seeds = list(
                    session.exec(
                        select(PlaylistItem.recording_id)
                        .where(PlaylistItem.playlist_id == liked)
                        .order_by(PlaylistItem.position.desc())  # type: ignore[attr-defined]
                        .limit(3)
                    ).all()
                )
        ninety = (utcnow() - timedelta(days=90)).replace(tzinfo=None)
        skipped_tracks = set(
            session.exec(
                select(SkipStreak.recording_id).where(
                    SkipStreak.user_id == user_id, SkipStreak.streak >= 2, SkipStreak.updated_at >= ninety
                )
            ).all()
        )
        from app.home import repetition

        skipped_tracks |= repetition.imported_skips(user_id)  # přeskočené ve Spotify (algoritmus, 180 dní)
        paused_offers, muted_offers = repetition.ignored_offers(user_id)
        small = len(act.total) < SMALL_PROFILE
        chosen: list[str] = _chosen_tracks(session, user_id) if small else []
        seed_artists = {r.artist_id for r in (session.get(Recording, s) for s in seeds) if r and r.artist_id}
        seed_title = None
        if seeds:
            first = session.get(Recording, seeds[-1])
            seed_title = first.title if first else None

    if seed_artists:
        near = act.co_listened_artists(seed_artists)
        # Poměr místo prostého souběhu (návrh 2): kdo hraje se vším (oblíbenci),
        # nevyhraje jen tím, že ho posloucháš pořád.
        freq = Counter(act.artist_of.get(r) for _t, r in act.timeline)
        lift = {a: n / (freq.get(a, 1) ** 0.5) for a, n in near.items()}
        top = max(lift.values(), default=1) or 1
        fit = {a: 0.3 + 0.7 * v / top for a, v in lift.items()}
        for a in seed_artists:
            fit[a] = 1.0
        reason = f"Navazuje na {seed_title}" if seed_title else "Navazuje na to, co hrálo"
    else:
        top = max(time_artists.values(), default=0) or 1.0
        # Denní doba podle množství dat: z pár poslechů se nedá poznat, co kdo
        # poslouchá ráno -- u malého profilu skoro neutrální (váha n/(n+K)).
        shrink = len(act.timeline) / (len(act.timeline) + TIME_SHRINK_K)
        fit = {a: (1 - shrink) + shrink * (0.15 + w / top) for a, w in time_artists.items()}
        reason = "Podle toho, co posloucháš v tuhle dobu" if shrink >= 0.5 else "Podle toho, co posloucháš"
    if mood == "prekvap":
        fit, time_artists = {}, Counter()  # bez denní doby -- celý vkus
        reason = "Překvap mě – víc nového"
    elif mood and moods is not None:
        label = MOODS[mood][2]
        fit = {a: fit.get(a, 0.3) * (0.08 + m) for a, m in moods.items()}
        reason = f"{label} – z toho, co posloucháš"
    if turn:
        # Dvakrát po sobě přeskočeno: jiným směrem -- interpreti přeskočených
        # ven a víc prostoru těm, které se dohrály.
        reason = "Zkouším jiný směr"
    from app.home.feedback import deltas as feedback_deltas
    from app.home.feedback import fit_multiplier

    manual = feedback_deltas(user_id)
    exclude = set(played) | recent | skipped_tracks | set(seeds)
    recent_batches = _recent_batch_ids(user_id) if not seeds else set()
    max_long = max(act.long.values(), default=0) or 1.0
    max_med = max(act.medium.values(), default=0) or 1.0
    # Tatáž píseň v jiné verzi ("Salt Creek" od Blake & Rice a pak od Rice
    # sólo) se v jedné session nevrací.
    played_titles = {_title_key(act.title_of.get(r, "")) for r in exclude} - {""}

    shrink_all = len(act.timeline) / (len(act.timeline) + TIME_SHRINK_K)
    default_time_fit = (1 - shrink_all) + shrink_all * 0.05
    # Malý profil: srdíčka a knihovna jako známé, i když je ještě neslyšel.
    chosen_meta = _rec_meta([r for r in chosen if r not in act.artist_of]) if chosen else {}
    for rid, (aid, title) in chosen_meta.items():
        if aid:
            act.artist_of.setdefault(rid, aid)
            act.title_of.setdefault(rid, title)
    chosen_set = set(chosen)
    audio = _features_map() if moods is not None and mood not in (None, "prekvap") else {}
    # Mladý profil: interpret jen z jednoho dne (zkoušení, puštěné pro
    # někoho) má malý vliv, dokud se nevrátí jiný den nebo nedostane srdíčko.
    tentative: dict[str, float] = {}
    if av.youngness(act.listening_days()) > 0:
        with Session(engine) as session:
            chosen_artists = {
                a for a in (act.artist_of.get(r) for r in (chosen or _chosen_tracks(session, user_id))) if a
            }
        tentative = av.tentative_factors(
            act.artist_days(), chosen_artists | {a for a, d in manual.items() if d > 0}, act.listening_days()
        )

    def score(rid: str) -> float:
        artist = act.artist_of.get(rid)
        if not artist or artist in banned or rid in exclude:
            return 0.0
        if _title_key(act.title_of.get(rid, "")) in played_titles:
            return 0.0
        base = act.medium.get(rid, 0.0) / max_med + 0.5 * act.long.get(rid, 0.0) / max_long
        if rid in chosen_set:
            base = max(base, 0.6)  # srdíčko / knihovna = "mám rád", i neslyšené
        if seed_artists:
            base = base ** 0.5  # navazování: podobnost víc než oblíbenost (návrh 2)
        f = fit.get(artist, 0.01 if moods is not None and mood != "prekvap" else
                    (0.05 if seed_artists else (default_time_fit if time_artists else 1.0)))
        if skipped_artists.get(artist):
            f *= 0.1 if turn else (0.3 if small else 0.4)
        if done_artists.get(artist):
            f *= 1.6 if small else 1.3  # malý profil: první relace učí rychleji
        if artist in manual:
            f *= fit_multiplier(manual[artist])  # "víc / míň takových"
        if session_counts.get(artist):
            f *= SESSION_DECAY ** session_counts[artist]
        if rid in recent_batches:
            f *= RECENT_BATCH_PENALTY
        if rid in muted_offers:
            f *= 0.3  # nabídnutá a nepuštěná -- týden méně často
        if rid in paused_offers:
            return 0.0
        if audio and rid in audio:
            f *= track_mood_fit(mood, *audio[rid])  # nálada i podle zvuku skladby
        if artist in tentative and not session_counts.get(artist) and not done_artists.get(artist):
            f *= tentative[artist]  # v právě běžící relaci platí, co hraje
        return base * f

    from app.home.personal_mixes import _cap_per_artist, _spread, _weighted_order

    ordered = _weighted_order(list(dict.fromkeys([*act.total, *chosen])), score, rng)
    seen_titles: set[str] = set()
    unique: list[str] = []
    for r in ordered:
        key = _title_key(act.title_of.get(r, ""))
        if score(r) > 0 and (not key or key not in seen_titles):
            seen_titles.add(key)
            unique.append(r)
    ordered = unique
    known_target = max(1, round(size * (1 - new_share)))
    from app.home import energy_flow

    familiar = _spread(_cap_per_artist(ordered, act.artist_of, 1)[:known_target], act.artist_of)
    if seed_artists and familiar and not any(act.artist_of.get(r) in seed_artists for r in familiar):
        # Nekonečné hraní drží směr (návrh 2): aspoň jedna skladba od
        # interpreta semínka, i když ho strop relace ztlumil.
        def seed_score(rid: str) -> float:
            artist = act.artist_of.get(rid)
            # Jen interpret, který v relaci ještě moc nehrál -- jinak by se
            # nekonečné hraní točilo kolem jedné kapely.
            if artist not in seed_artists or session_counts.get(artist, 0) >= 3:
                return 0.0
            if rid in exclude or rid in familiar:
                return 0.0
            if _title_key(act.title_of.get(rid, "")) in played_titles:
                return 0.0
            return act.medium.get(rid, 0.0) / max_med + 0.5 * act.long.get(rid, 0.0) / max_long

        seeded = [r for r in _weighted_order(list(act.total), seed_score, rng) if seed_score(r) > 0]
        if seeded:
            familiar = (familiar[:-1] if len(familiar) >= known_target else familiar) + [seeded[0]]
    familiar = energy_flow.order(familiar, act.artist_of)  # plynulé navazování (P3)
    if ctx is not None:
        # Filtry i pro nové skladby (audit F) -- stejné jako pro známé.
        ctx.update(
            banned=set(banned),
            muted={a for a, d in manual.items() if fit_multiplier(d) < 1},
            skipped_artists={a for a, n in skipped_artists.items() if n},
            titles=(played_titles | {_title_key(act.title_of.get(r, "")) for r in familiar}) - {""},
            session_counts=session_counts,
            paused=paused_offers,
            weak_mood=bool(
                moods is not None and mood != "prekvap" and sum(1 for m in moods.values() if m >= 0.3) < 3
            ),
        )
    # Semínka pro nové: semínka nekonečného hraní, jinak první známé.
    new_seeds = (seeds[-2:] if seeds else []) + familiar[:2]
    if small and not seeds:
        # Malý profil: z RŮZNÝCH interpretů všeho, co slyšel a co má rád --
        # jinak by po jedné písničce uvízl v jedné škatulce.
        pool = list(dict.fromkeys([*recent_order, *sorted(act.total, key=lambda r: -act.total[r]), *chosen, *familiar]))
        # Potvrzený vkus napřed, jednorázové zkoušení až za ním.
        pool.sort(key=lambda r: act.artist_of.get(r) in tentative)
        new_seeds = _distinct_artist_seeds(pool, act.artist_of, 4) or new_seeds
        if not familiar and new_seeds:
            meta = _rec_meta(new_seeds[:1])
            if meta.get(new_seeds[0], (None, ""))[1]:
                reason = f"Navazuje na {meta[new_seeds[0]][1]}"
    if not new_seeds and fallback_seeds:
        new_seeds = fallback_seeds
        with Session(engine) as session:
            first = session.get(Recording, fallback_seeds[0])
        reason = f"Navazuje na {first.title}" if first else reason
    return familiar, new_seeds, reason


# Nálada podle ZVUKU skladby (bod 4, opentify-notes/rozbor-zvuku-navrh-
# 2026-10-07.md): štítky říkají jen, jaký je interpret -- klidná píseň
# energické kapely (nebo naopak) tak propadla. Energie 0-1 z rozboru zvuku
# (decily 0,08 ... 0,88), tempo jen se spolehlivým odhadem.
def track_mood_fit(mood: str | None, energy: float | None, bpm: float | None = None) -> float:
    """Násobek pro skladbu v náladě (1 = beze změny / bez rozboru)."""
    if energy is None or mood in (None, "prekvap"):
        return 1.0
    e = energy
    if mood == "klid":
        return 1.5 if e < 0.35 else 1.0 if e < 0.5 else 0.5 if e < 0.65 else 0.2
    if mood == "energie":
        f = 1.5 if e > 0.65 else 1.0 if e > 0.5 else 0.5 if e > 0.35 else 0.2
        return f * (1.1 if bpm and bpm >= 120 else 1.0)
    if mood == "melancholie":
        return 1.3 if e < 0.5 else 0.8 if e < 0.65 else 0.3
    if mood == "party":
        f = 1.4 if e > 0.6 else 0.9 if e > 0.45 else 0.3
        return f * (1.15 if bpm and 100 <= bpm <= 135 else 1.0)
    if mood == "soustredeni":
        return 1.2 if 0.15 <= e <= 0.6 else 0.9 if e < 0.15 else 0.3 if e > 0.75 else 0.7
    return 1.0


_feat_cache: tuple[float, dict[str, tuple[float | None, float | None]]] | None = None


def _features_map() -> dict[str, tuple[float | None, float | None]]:
    """Skladba -> (energie, spolehlivé tempo); cache 10 min."""
    global _feat_cache
    if _feat_cache and time.time() - _feat_cache[0] < _CACHE_SECONDS:
        return _feat_cache[1]
    from app.home.energy_flow import TEMPO_MIN_CONFIDENCE
    from app.models import TrackFeatures

    with Session(engine) as session:
        rows = session.exec(select(TrackFeatures.recording_id, TrackFeatures.energy, TrackFeatures.bpm, TrackFeatures.bpm_confidence)).all()
    out = {r: (e, b if (c or 0) >= TEMPO_MIN_CONFIDENCE else None) for r, e, b, c in rows}
    _feat_cache = (time.time(), out)
    return out


MAX_DEFERRED_SHARE = 0.5  # nanejvýš polovinu nových odložit do další várky
SMOOTH_TIMEOUT_S = 3.0


async def _smooth(
    out: list[str], new_ids: set[str], anchor: str | None, mood: str | None
) -> tuple[list[str], set[str]]:
    """Plynulé přechody v celé várce (bod 4 + nahlášený skok YUNGBLUD ->
    Tenório Jr., 7. 10.):
    1. nové skladby bez rozboru -> rozbor z 30s ukázky Deezeru (nejvýš 4 s);
    2. nové, které zvukem odporují zvolené náladě, ven;
    3. celou várku (známé i nové) seřadit od skladby, která právě hraje
       (energie konce -> začátku, tempo, vzdálenost stylů);
    4. novou skladbu, která i tak dělá velký skok, odložit do další várky.
    Vrací (pořadí, nové)."""
    from app import preview_features
    from app.home import energy_flow, taste_bridge

    meta = await asyncio.to_thread(_rec_meta, out + ([anchor] if anchor else []))
    artist_of = {r: a for r, (a, _t) in meta.items() if a}
    # Rozbor ukázek a štítky stylů souběžně, dohromady nejvýš ~3 s (dřív až
    # 10 s při studené cache); co nestihne, doběhne a pomůže příští várce.
    styles_task = asyncio.ensure_future(taste_bridge.artist_styles(list(set(artist_of.values()))))
    _prefetching.add(styles_task)  # držet odkaz, ať doběhne i po limitu
    styles_task.add_done_callback(_prefetching.discard)
    await preview_features.ensure([r for r in out if r in new_ids], timeout_s=SMOOTH_TIMEOUT_S)
    try:
        styles = await asyncio.wait_for(asyncio.shield(styles_task), timeout=1.0)
    except asyncio.TimeoutError:
        styles = {}  # štítky se dotáhnou do cache na pozadí
    if mood not in (None, "prekvap") and new_ids:
        global _feat_cache
        _feat_cache = None  # právě rozebrané ukázky
        audio = await asyncio.to_thread(_features_map)
        out = [r for r in out if r not in new_ids or track_mood_fit(mood, *audio.get(r, (None, None))) > 0.3]
    ordered = await asyncio.to_thread(energy_flow.order, out, artist_of, anchor, styles)
    news = [r for r in ordered if r in new_ids]
    budget = max(1, round(len(news) * MAX_DEFERRED_SHARE)) if news else 0
    deferred: list[str] = []
    for _ in range(budget):
        bad = await asyncio.to_thread(energy_flow.jumps, ordered, artist_of, styles, anchor)
        culprit = None
        for i, _e, _d in bad:
            after = ordered[i + 1] if i + 1 < len(ordered) else None
            before = ordered[i] if i >= 0 else None
            culprit = after if after in new_ids else (before if before in new_ids else None)
            if culprit:
                break
        if not culprit:
            break
        deferred.append(culprit)
        ordered = await asyncio.to_thread(
            energy_flow.order, [r for r in ordered if r != culprit], artist_of, anchor, styles
        )
    if deferred:
        logger.info("pusť teď: %d nových odloženo kvůli skoku stylu/energie", len(deferred))
    return ordered, {r for r in new_ids if r in ordered}


def _rec_meta(recording_ids: list[str]) -> dict[str, tuple[str | None, str]]:
    """Skladba -> (interpret, název) jedním dotazem."""
    if not recording_ids:
        return {}
    with Session(engine) as session:
        rows = session.exec(
            select(Recording.id, Recording.artist_id, Recording.title).where(Recording.id.in_(recording_ids))  # type: ignore[attr-defined]
        ).all()
    return {rid: (aid, title or "") for rid, aid, title in rows}


def _available(recording_ids: list[str]) -> set[str]:
    from app.models import MediaAsset, MediaAssetStatus

    if not recording_ids:
        return set()
    with Session(engine) as session:
        return set(
            session.exec(
                select(MediaAsset.recording_id).where(
                    MediaAsset.recording_id.in_(recording_ids),  # type: ignore[attr-defined]
                    MediaAsset.status == MediaAssetStatus.AVAILABLE,
                )
            ).all()
        )


def _safe_start(out: list[str], available: set[str], first: int = 2) -> list[str]:
    """Prvních `first` míst jen stažené (návrh 3) -- jistý start bez čekání;
    nestažené se posunou za ně, pořadí ostatních zůstane."""
    head = [r for r in out if r in available][:first]
    rest = [r for r in out if r not in head]
    return head + rest


async def _prefetch(user_id: str, recording_ids: list[str]) -> None:
    """Nestažené skladby várky obstarat hned na pozadí (návrh 3) -- dřív se
    ~každá 4. nová stahovala až při puštění. V limitech stahování profilu;
    přes limit se nic nezakládá."""
    from fastapi import HTTPException

    from app import download_limits
    from app.provisioning_service import enqueue, get_or_create_job, would_create_job

    admin = await asyncio.to_thread(download_limits.is_admin, user_id)

    def _job(rid: str):
        with Session(engine) as session:
            if not would_create_job(session, rid):
                return None, False
            _asset, job, created = get_or_create_job(session, rid, user_id, None)
            if job is not None:
                session.expunge(job)
            return job, created

    for rid in recording_ids:
        try:
            if not admin:
                await download_limits.check_music(user_id)
            job, created = await asyncio.to_thread(_job, rid)
            if job is not None and created:
                await download_limits.count_music(user_id)
                await enqueue(job, interactive=False)
        except HTTPException:
            return  # limit -- zbytek se stáhne až při puštění (a zase narazí)
        except Exception:  # noqa: BLE001 -- jen předstažení
            continue


async def _mood_tag_tracks(mood: str, exclude: set[str], rng: random.Random, want: int) -> list[str]:
    """Nové skladby přímo podle štítku nálady (Last.fm), když profil na
    náladu skoro nic nemá (návrh 5)."""
    from app.catalog import lastfm
    from app.tags import _resolve_tracks

    _category, extra, _label = MOODS[mood]
    items: list[dict[str, str]] = []
    for tag in extra[:2]:
        try:
            items += await lastfm.tag_top_tracks(tag, 40)
        except Exception:  # noqa: BLE001
            continue
    rng.shuffle(items)
    try:
        ids = await _resolve_tracks(items, want * 2)
    except Exception:  # noqa: BLE001
        return []
    return [r for r in ids if r not in exclude][: want * 2]


async def next_chunk(
    user_id: str, seeds: list[str], played: list[str], size: int = 8, mood: str | None = None
) -> dict[str, Any]:
    from app.home import lastfm_taste as lt
    from app.home.personal_mixes import _drop_heard

    rng = random.Random(f"{user_id}:{int(time.time() // 60)}:{len(played)}")
    mood = mood if mood in MOODS else None
    seeds = await asyncio.to_thread(_clean_seeds, user_id, seeds)
    moods = None
    if mood and mood != "prekvap":
        moods = await mood_fit(await asyncio.to_thread(_activation, user_id), mood)
    weak_mood = bool(moods is not None and sum(1 for m in moods.values() if m >= 0.3) < 3)
    new_share = 0.5 if mood == "prekvap" else (0.6 if weak_mood else NEW_SHARE)
    if mood != "prekvap" and len((await asyncio.to_thread(_activation, user_id)).total) < SMALL_PROFILE:
        new_share = max(new_share, SMALL_NEW_SHARE)  # čistý start: není co opakovat
    session_counts = await session_artist_counts(played)
    ctx: dict[str, Any] = {}
    familiar, new_seeds, reason = await asyncio.to_thread(
        pick, user_id, seeds, played, size, rng, mood, moods, new_share, session_counts, ctx
    )
    if weak_mood and mood:
        reason = f"{MOODS[mood][2]} – u tebe toho na tohle moc není, zkouším i nové"
    want_new = size - len(familiar)
    new: list[str] = []
    if want_new > 0 and (new_seeds or weak_mood):
        act = _activation(user_id)
        exclude = set(act.total) | set(played) | set(familiar) | set(seeds) | set(ctx.get("paused") or ())
        cands: list[str] = []
        if weak_mood and mood:
            try:
                cands += await asyncio.wait_for(_mood_tag_tracks(mood, exclude, rng, want_new), timeout=12)
            except Exception:  # noqa: BLE001
                pass
        if new_seeds:
            try:
                cands += await asyncio.wait_for(lt.similar_track_ids(new_seeds, exclude, rng, want_new * 2), timeout=12)
            except Exception:  # noqa: BLE001 -- bez nových je to pořád dobrá várka
                pass
        cands = list(dict.fromkeys(cands))

        class _T:  # _drop_heard čte jen .activation
            activation = act

        new = await asyncio.to_thread(_drop_heard, _T, cands)
        meta = await asyncio.to_thread(_rec_meta, new)
        # Nový interpret ne zároveň mezi známými ani dvakrát mezi novými; a
        # stejné filtry jako u známých (audit F): neoblíbení, "míň takových",
        # přeskočení v relaci, už hodně hraní, tatáž píseň (návrh 7).
        used = {act.artist_of.get(r) for r in familiar}
        blocked = ctx.get("banned", set()) | ctx.get("muted", set()) | ctx.get("skipped_artists", set())
        titles = set(ctx.get("titles", set()))
        counts = ctx.get("session_counts", Counter())
        kept = []
        for rid in new:
            a, title = meta.get(rid, (None, ""))
            key = _title_key(title)
            if not a or a in used or a in blocked or counts.get(a, 0) >= 2:
                continue
            if key and key in titles:
                continue
            used.add(a)
            titles.add(key)
            kept.append(rid)
        new = kept[:want_new]
    new_ids = set(new)
    # Nové proložit mezi známé (ne všechny na konec).
    out: list[str] = []
    step = max(1, len(familiar) // max(1, len(new))) if new else len(familiar) or 1
    fi = iter(familiar)
    for i in range(len(familiar) + len(new)):
        if new and (i + 1) % (step + 1) == 0:
            out.append(new.pop(0))
        else:
            nxt = next(fi, None)
            if nxt is None:
                out.extend(new)
                break
            out.append(nxt)
    out = out[:size]
    if not out:
        # Nový profil bez historie: nic nevnucovat (žádné žebříčky), jen říct proč.
        reason = "Zatím nevím, co posloucháš – pusť si něco z Hledat a příště navážu."
        return {"recordingIds": [], "reason": reason}
    try:
        out, new_ids = await _smooth(out, new_ids, seeds[-1] if seeds else None, mood)
    except Exception:  # noqa: BLE001 -- plynulost je doplněk, várka musí přijít
        logger.exception("pusť teď: plynulé řazení")
    available = await asyncio.to_thread(_available, out)
    out = _safe_start(out, available)
    missing = [r for r in out if r not in available]
    if missing:
        task = asyncio.get_running_loop().create_task(_prefetch(user_id, missing))
        _prefetching.add(task)
        task.add_done_callback(_prefetching.discard)
    _remember_batch(user_id, out)
    try:
        from app import rec_log

        mode = f"mood:{mood}" if mood else ("endless" if seeds else "fresh")
        await asyncio.to_thread(rec_log.log_batch, user_id, out, new_ids, mode)
    except Exception:  # noqa: BLE001 -- měření nesmí shodit várku
        pass
    return {"recordingIds": out, "reason": reason}


_prefetching: set[asyncio.Task] = set()


async def warm_mood_tags_loop(hour: int = 4, top: int = 80) -> None:
    """V noci (4:00) načte štítky Last.fm top interpretů každého profilu do
    cache (den), ať první čip nálady čeká ~1 s místo ~20 s (návrh 9). Na
    pozadí -- uživatel má přednost (app/catalog/rate_limit.py)."""
    from datetime import datetime
    from zoneinfo import ZoneInfo

    from app.catalog.rate_limit import mark_background
    from app.home import lastfm_taste as lt
    from app.models import AppUser, Artist

    mark_background()
    tz = ZoneInfo("Europe/Prague")
    done_day = None
    while True:
        await asyncio.sleep(600)
        now = datetime.now(tz)
        if now.hour != hour or done_day == now.date():
            continue
        done_day = now.date()
        try:
            with Session(engine) as session:
                users = list(session.exec(select(AppUser.id)).all())
            for user_id in users:
                act = await asyncio.to_thread(_activation, user_id)
                artists = [a for a, _ in act.blend(av.ARTIST_BLEND).most_common(top)]
                with Session(engine) as session:
                    names = [n for n in session.exec(select(Artist.name).where(Artist.id.in_(artists))).all() if n]  # type: ignore[attr-defined]
                for name in names:
                    try:
                        await lt.artist_tags(name)
                    except Exception:  # noqa: BLE001
                        continue
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 -- smyčka nesmí umřít
            import logging

            logging.getLogger(__name__).exception("předehřátí štítků nálad selhalo")


async def start_from(user_id: str, artist_id: str | None, recording_id: str | None, size: int = 10) -> dict[str, Any]:
    """Start Pusť teď u profilu bez dat: zadaný interpret (2 jeho
    nejposlouchanější skladby napřed) nebo skladba, pak navazující nové."""
    from app.catalog.top_tracks import artist_top_tracks
    from app.home import lastfm_taste as lt

    head: list[str] = []
    title = ""
    if recording_id:
        head = [recording_id]
        meta = await asyncio.to_thread(_rec_meta, [recording_id])
        title = (meta.get(recording_id) or (None, ""))[1]
    elif artist_id:
        try:
            top = await artist_top_tracks(artist_id)
        except Exception:  # noqa: BLE001
            top = []
        head = [t["id"] for t in top[:2] if t.get("id")]
        from app.models import Artist

        with Session(engine) as session:
            artist = session.get(Artist, artist_id)
            title = artist.name if artist else ""
    if not head:
        return {"recordingIds": [], "reason": "Tohle se nepodařilo najít – zkus jiného interpreta."}
    rng = random.Random(f"{user_id}:start:{int(time.time() // 60)}")
    seeds = head[:2]
    try:
        cands = await asyncio.wait_for(lt.similar_track_ids(seeds, set(head), rng, size * 2), timeout=12)
    except Exception:  # noqa: BLE001
        cands = []
    meta = await asyncio.to_thread(_rec_meta, cands)
    per_artist: Counter = Counter()
    head_artists = {a for a, _t in (await asyncio.to_thread(_rec_meta, head)).values() if a}
    new: list[str] = []
    for rid in cands:
        a = meta.get(rid, (None, ""))[0]
        if not a or a in head_artists or per_artist[a] >= 1:
            continue
        per_artist[a] += 1
        new.append(rid)
    out = (head + new)[:size]
    available = await asyncio.to_thread(_available, out)
    missing = [r for r in out if r not in available]
    if missing:
        task = asyncio.get_running_loop().create_task(_prefetch(user_id, missing))
        _prefetching.add(task)
        task.add_done_callback(_prefetching.discard)
    try:
        from app import rec_log

        await asyncio.to_thread(rec_log.log_batch, user_id, out, set(new), "start")
    except Exception:  # noqa: BLE001
        pass
    return {"recordingIds": out, "reason": f"Začínám od {title} a navážu podobným" if title else "Začínám"}
