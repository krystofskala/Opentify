"""Volitelné sekce Domů (Profil › Domů -- ve výchozím stavu vypnuté).

Každá sekce má sestavení na pozadí (`build_*`, jen pro profily, které ji mají
zapnutou) a výsledek v `HomeSnapshot` "xsec:<id>:<user>" ve tvaru
{"title", "kind": tracks|albums|artists, "ids", "playlistId"?, "badges"?}.
Domů pak jen čte (`render`) -- rychle, bez dotazů ven.

Sekce:
- now_mix          Mix na teď -- co posloucháš v tuhle denní dobu + podobné
- year_ago         Tento týden před rokem
- forgotten        Zapomenuté poklady -- alba, která jsi hrál hodně, ale dlouho ne
- unfinished       Dokonči album -- rozposlouchaná alba
- anniversaries    Výročí alb z tvé knihovny
- release_radar    Novinky od tvých interpretů
- deep_cuts        Méně známé skladby tvých oblíbených
- artist_discovery Interpreti, které bys mohl znát
- album_picks      Celá alba pro tebe
- shazam           Z tvého Shazamu
- soundcloud       Na SoundCloudu od tvých interpretů (věci, které jinde nejsou)
- family           Co poslouchá rodina (jen profily, které sdílení povolí)
"""

from __future__ import annotations

import asyncio
import logging
import math
import random
from collections import Counter, defaultdict
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Any, Awaitable, Callable
from zoneinfo import ZoneInfo

from sqlmodel import Session, select

from app.catalog.artwork import _normalize
from app.catalog.identity import is_own_artist
from app.db import engine
from app.models import (
    AppUser,
    Artist,
    FavoriteArtist,
    HomeSnapshot,
    LibraryEntry,
    Listen,
    ListenLater,
    PlaylistKind,
    Recording,
    Release,
)
from app.utils import utcnow

logger = logging.getLogger("vault.home.extra")
_TZ = ZoneInfo("Europe/Prague")


@dataclass(frozen=True)
class Spec:
    id: str
    title: str
    ttl: timedelta
    build: Callable[[str], Awaitable[int]] | None  # None = počítá se živě v render()


def key(section_id: str, user_id: str) -> str:
    return f"xsec:{section_id}:{user_id}"


def _aware(dt):
    from datetime import timezone

    return dt if dt.tzinfo else dt.replace(tzinfo=timezone.utc)


def _save(user_id: str, section_id: str, payload: dict[str, Any]) -> None:
    with Session(engine) as s:
        row = s.get(HomeSnapshot, key(section_id, user_id)) or HomeSnapshot(key=key(section_id, user_id))
        row.payload = payload
        row.generated_at = utcnow()
        s.add(row)
        s.commit()


def _clear(user_id: str, section_id: str) -> None:
    _save(user_id, section_id, {"ids": []})


def _artist_weights(user_id: str, days: int = 365, half_life: float = 60.0) -> tuple[Counter, dict[str, str]]:
    """Váha interpretů podle poslechů (čerstvé víc) + oblíbení interpreti."""
    now = utcnow()
    weights: Counter = Counter()
    with Session(engine) as s:
        rows = s.exec(
            select(Recording.artist_id, Listen.played_at)
            .join(Recording, Recording.id == Listen.recording_id)
            .where(Listen.user_id == user_id, Listen.played_at >= now - timedelta(days=days))
        ).all()
        for artist_id, played in rows:
            if artist_id:
                weights[artist_id] += 0.5 ** ((now - _aware(played)).total_seconds() / 86400 / half_life)
        for fav in s.exec(select(FavoriteArtist.artist_id).where(FavoriteArtist.user_id == user_id)).all():
            weights[fav] += 3.0
        from app.library.dislikes import disliked_artist_ids

        for banned in disliked_artist_ids(s, user_id):
            weights.pop(banned, None)  # nelíbení interpreti nic nedoporučují
        names = {a.id: a.name for a in s.exec(select(Artist).where(Artist.id.in_(list(weights)))).all()}  # type: ignore[attr-defined]
    return weights, names


def _save_playlist(user_id: str, source: str, title: str, description: str, ids: list[str], ttl: timedelta) -> str:
    from app.home import generators as g

    return g._save_playlist(
        owner=user_id, source=source, title=title, description=description, kind=PlaylistKind.PERSONAL_MIX,
        section="extra", recording_ids=ids, cover_urls=g._covers_for(ids[:4]), ttl=ttl,
    )


# ----------------------------------------------------------------------
# Mix na teď
# ----------------------------------------------------------------------

_BANDS = [(5, 11, "Ranní mix"), (11, 17, "Odpolední mix"), (17, 22, "Večerní mix"), (22, 29, "Noční mix")]


def _band(hour: int) -> str:
    h = hour if hour >= 5 else hour + 24
    return next(name for lo, hi, name in _BANDS if lo <= h < hi)


def _artist_names(recording_ids: list[str]) -> dict[str, str]:
    """Jména interpretů pro štítky Last.fm -- bez vlastních (Kontrast), u nich
    by Last.fm vrátil styly cizí stejnojmenné kapely."""
    with Session(engine) as s:
        rows = s.exec(
            select(Recording.id, Artist).join(Artist, Artist.id == Recording.artist_id).where(Recording.id.in_(recording_ids))  # type: ignore[attr-defined]
        ).all()
    return {rid: a.name for rid, a in rows if not is_own_artist(a)}


async def _artist_styles(name: str) -> list[str]:
    from app.home import lastfm_taste as lt

    try:
        return (await lt.artist_tags(name))[:5]
    except Exception:  # noqa: BLE001 -- Last.fm výpadek = bez stylu
        return []


async def _dominant_style(top: list[str], weights: Counter) -> tuple[str | None, Any]:
    """Nejhranější styl mezi skladbami (štítky interpretů z Last.fm, silnější
    štítek víc) a funkce "sedí skladba do něj"."""
    names = await asyncio.to_thread(_artist_names, top)
    styles: dict[str, list[str]] = {}
    for name in dict.fromkeys(names.values()):
        styles[name] = await _artist_styles(name)
    score: Counter = Counter()
    for rid in top:
        for pos, tag in enumerate(styles.get(names.get(rid, ""), [])[:3]):
            score[tag] += weights[rid] * (1.0, 0.7, 0.5)[pos]
    if not score:
        return None, lambda _r: True
    style = score.most_common(1)[0][0]
    return style, lambda rid: style in styles.get(names.get(rid, ""), [])


async def _has_style(recording_id: str, style: str) -> bool:
    name = (await asyncio.to_thread(_artist_names, [recording_id])).get(recording_id)
    return bool(name) and style in await _artist_styles(name)


async def build_now_mix(user_id: str) -> int:
    """Skladby, které hraješ v tuhle denní dobu (všední den / víkend zvlášť),
    + to, co posluchači pouštějí spolu s nimi. Přegeneruje se při změně části
    dne (ráno / odpoledne / večer / noc)."""
    from app.home import lastfm_taste as lt
    from app.home.quick_picks import time_profile

    local = utcnow().astimezone(_TZ)
    band = _band(local.hour)
    stamp = f"{local.date().isoformat()}:{band}"
    with Session(engine) as s:
        row = s.get(HomeSnapshot, key("now_mix", user_id))
        if row and (row.payload or {}).get("stamp") == stamp and (row.payload or {}).get("ids"):
            return len(row.payload["ids"])
        _ctx, _artists, recs = time_profile(s, user_id)
    if len(recs) < 8:
        _clear(user_id, "now_mix")
        return 0
    rng = random.Random(stamp)
    top = [r for r, _w in recs.most_common(80)]
    # Jeden styl na mix (živě: večerní mix skákal mezi žánry) -- styl, který
    # v tuhle dobu hraješ nejvíc; skladby i "podobné" jen z něj.
    style, fits = await _dominant_style(top, recs)
    in_style = [r for r in top if fits(r)] if style else top
    if len(in_style) < 8:
        in_style, style = top, None
    own = in_style[:40]
    rng.shuffle(own)
    own = own[:24]
    similar = await lt.similar_track_ids(in_style[:6], set(top), rng, 32 if style else 16)
    if style:
        similar = [r for r in similar if await _has_style(r, style)][:16]
    ids: list[str] = []
    while own or similar:
        ids += own[:2]
        own = own[2:]
        ids += similar[:1]
        similar = similar[1:]
    ids = list(dict.fromkeys(ids))[:40]
    what = f"{style} -- " if style else ""
    pid = _save_playlist(user_id, "personal:now-mix", band, f"{band}: {what}co v tuhle dobu posloucháš a podobné", ids, timedelta(hours=8))
    _save(user_id, "now_mix", {"title": f"Mix na teď · {band}", "kind": "tracks", "ids": ids[:20], "playlistId": pid, "stamp": stamp})
    return len(ids)


# ----------------------------------------------------------------------
# Tento týden před rokem
# ----------------------------------------------------------------------

async def build_year_ago(user_id: str) -> int:
    """Nejhranější skladby z týdne kolem dnešního dne před rokem (když tehdy
    nic, před dvěma / třemi lety)."""
    today = utcnow().astimezone(_TZ).date()

    def collect(years: int) -> list[str]:
        try:
            center = today.replace(year=today.year - years)
        except ValueError:  # 29. února
            center = today.replace(year=today.year - years, day=28)
        lo = center - timedelta(days=3)
        hi = center + timedelta(days=4)
        with Session(engine) as s:
            rows = s.exec(
                select(Listen.recording_id).where(
                    Listen.user_id == user_id, Listen.played_at >= lo, Listen.played_at < hi
                )
            ).all()
        counts = Counter(rows)
        return [r for r, _c in counts.most_common(40)]

    for years, label in ((1, "Tento týden před rokem"), (2, "Tento týden před dvěma lety"), (3, "Tento týden před třemi lety")):
        ids = await asyncio.to_thread(collect, years)
        if len(ids) >= 8:
            pid = _save_playlist(user_id, "personal:year-ago", label, f"{label} -- co ti tehdy hrálo nejvíc", ids, timedelta(hours=12))
            _save(user_id, "year_ago", {"title": label, "kind": "tracks", "ids": ids[:20], "playlistId": pid})
            return len(ids)
    _clear(user_id, "year_ago")
    return 0


# ----------------------------------------------------------------------
# Alba: zapomenuté poklady, dokonči album, výročí
# ----------------------------------------------------------------------

def _release_stats(user_id: str) -> dict[str, dict[str, Any]]:
    """Po albech: počet poslechů, různé skladby, poslední poslech, kontext alba."""
    stats: dict[str, dict[str, Any]] = defaultdict(lambda: {"count": 0, "tracks": set(), "last": None, "ctx_tracks": set(), "ctx_last": None})
    with Session(engine) as s:
        for rid, release_id, played, context in s.exec(
            select(Listen.recording_id, Recording.release_id, Listen.played_at, Listen.context)
            .join(Recording, Recording.id == Listen.recording_id)
            .where(Listen.user_id == user_id)
        ).all():
            if not release_id:
                continue
            st = stats[release_id]
            played = _aware(played)
            st["count"] += 1
            st["tracks"].add(rid)
            st["last"] = played if st["last"] is None or played > st["last"] else st["last"]
            if context == f"/releases/{release_id}":
                st["ctx_tracks"].add(rid)
                st["ctx_last"] = played if st["ctx_last"] is None or played > st["ctx_last"] else st["ctx_last"]
    return stats


def _ago(days: float) -> str:
    if days >= 365:
        years = int(days // 365)
        return "před rokem" if years == 1 else f"před {years} lety"
    months = max(1, int(days // 30))
    return "před měsícem" if months == 1 else f"před {months} měsíci"


async def build_forgotten(user_id: str) -> int:
    """Alba, která jsi hrál hodně (12+ poslechů, 3+ různé skladby), ale přes
    půl roku ne -- nejhranější napřed."""
    stats = await asyncio.to_thread(_release_stats, user_id)
    now = utcnow()
    picks = []
    with Session(engine) as s:
        for release_id, st in stats.items():
            if st["count"] < 12 or len(st["tracks"]) < 3 or st["last"] is None:
                continue
            idle = (now - st["last"]).total_seconds() / 86400
            if idle < 180:
                continue
            rel = s.get(Release, release_id)
            if rel is None or (rel.release_type or "album") not in ("album", "ep"):
                continue
            picks.append((st["count"] * math.log(len(st["tracks"]) + 1), release_id, _ago(idle)))
    picks.sort(reverse=True)
    rng = random.Random(f"forgotten:{user_id}:{now.date().isoformat()}")
    top = picks[:30]
    rng.shuffle(top)  # denně jiný výběr z nejsilnějších
    top = sorted(top[:12], reverse=True)
    _save(
        user_id, "forgotten",
        {"title": "Zapomenuté poklady", "kind": "albums", "ids": [r for _s, r, _a in top], "badges": {r: f"naposledy {a}" for _s, r, a in top}},
    )
    return len(top)


async def build_unfinished(user_id: str) -> int:
    """Alba pouštěná jako album (posledních 45 dní), ze kterých jsi slyšel
    aspoň 2, ale méně než 70 % skladeb."""
    stats = await asyncio.to_thread(_release_stats, user_id)
    now = utcnow()
    picks = []
    with Session(engine) as s:
        for release_id, st in stats.items():
            if not st["ctx_last"] or now - st["ctx_last"] > timedelta(days=45) or now - st["ctx_last"] < timedelta(hours=6):
                continue
            if len(st["ctx_tracks"]) < 2:
                continue
            total = len(s.exec(select(Recording.id).where(Recording.release_id == release_id)).all())
            heard = len(st["tracks"])
            if total < 5 or heard >= total * 0.7:
                continue
            picks.append((st["ctx_last"], release_id, total - heard))
    picks.sort(reverse=True)
    picks = picks[:12]
    left = lambda n: "zbývá 1 skladba" if n == 1 else (f"zbývají {n} skladby" if n < 5 else f"zbývá {n} skladeb")  # noqa: E731
    _save(
        user_id, "unfinished",
        {"title": "Dokonči album", "kind": "albums", "ids": [r for _l, r, _n in picks], "badges": {r: left(n) for _l, r, n in picks}},
    )
    return len(picks)


async def build_anniversaries(user_id: str) -> int:
    """Alba z tvé historie / knihovny, která v těchto dnech (±3 dny) slaví
    výročí vydání -- kulatá napřed. Jen přesná data (rok-měsíc-den), u alb
    z MusicBrainz první vydání (ne reedice)."""
    stats = await asyncio.to_thread(_release_stats, user_id)
    today = utcnow().astimezone(_TZ).date()
    with Session(engine) as s:
        lib_releases = Counter(
            s.exec(
                select(Recording.release_id)
                .join(LibraryEntry, LibraryEntry.recording_id == Recording.id)
                .where(LibraryEntry.user_id == user_id)
            ).all()
        )
        candidates = {r for r, st in stats.items() if st["count"] >= 5} | {r for r, c in lib_releases.items() if r and c >= 3}
        picks = []
        for release_id in candidates:
            rel = s.get(Release, release_id)
            if rel is None or not rel.release_date or len(rel.release_date) != 10:
                continue
            if (rel.release_type or "album") not in ("album", "ep"):
                continue
            try:
                released = date.fromisoformat(rel.release_date)
            except ValueError:
                continue
            years = today.year - released.year
            if years < 1:
                continue
            try:
                this_year = released.replace(year=today.year)
            except ValueError:
                this_year = released.replace(year=today.year, day=28)
            delta = (this_year - today).days
            if abs(delta) > 3:
                continue
            round_ = years % 5 == 0
            when = "dnes" if delta == 0 else ("zítra" if delta == 1 else ("včera" if delta == -1 else ""))
            word = "rok" if years == 1 else ("roky" if years < 5 else "let")
            badge = f"{when + ' ' if when else ''}{years} {word}".strip()
            score = (1 if round_ else 0, -abs(delta), stats.get(release_id, {}).get("count", 0))
            picks.append((score, release_id, badge))
    picks.sort(reverse=True)
    picks = picks[:12]
    _save(
        user_id, "anniversaries",
        {"title": "Výročí alb", "kind": "albums", "ids": [r for _s, r, _b in picks], "badges": {r: b for _s, r, b in picks}},
    )
    return len(picks)


# ----------------------------------------------------------------------
# Novinky od tvých interpretů
# ----------------------------------------------------------------------

async def build_release_radar(user_id: str) -> int:
    """Nová alba / EP / singly (posledních 6 týdnů) od interpretů, které
    posloucháš (top 60 podle poslechů) a oblíbených -- nejnovější napřed."""
    from app.catalog.deezer import get_deezer_client
    from app.catalog.deezer_ingest import ingest_album

    weights, _names = await asyncio.to_thread(_artist_weights, user_id, 365, 90.0)
    artist_ids = [a for a, _w in weights.most_common(60)]
    dz = get_deezer_client()
    cutoff = (utcnow().date() - timedelta(days=42)).isoformat()
    sem = asyncio.Semaphore(6)
    with Session(engine) as s:
        dz_ids = {a.id: a.deezer_id for a in s.exec(select(Artist).where(Artist.id.in_(artist_ids))).all() if a.deezer_id}  # type: ignore[attr-defined]

    async def albums_of(artist_id: str) -> tuple[str, list[dict]]:
        async with sem:
            try:
                return artist_id, await dz.artist_albums(dz_ids[artist_id]) or []
            except Exception:  # noqa: BLE001
                return artist_id, []

    results = await asyncio.gather(*(albums_of(a) for a in artist_ids if a in dz_ids))
    fresh: list[tuple[str, str, dict]] = []
    for artist_id, albums in results:
        for a in albums:
            if (a.get("release_date") or "") >= cutoff and a.get("record_type") != "compile":
                fresh.append((a.get("release_date") or "", artist_id, a))
    fresh.sort(key=lambda x: x[0], reverse=True)
    ids: list[str] = []
    badges: dict[str, str] = {}
    with Session(engine) as s:
        for released, artist_id, a in fresh[:30]:
            artist = s.get(Artist, artist_id)
            rel = ingest_album(s, a, artist) if artist else None
            if rel is None or rel.id in ids:
                continue
            ids.append(rel.id)
            kind = {"single": "singl", "ep": "EP"}.get(a.get("record_type") or "", "album")
            days = (utcnow().date() - date.fromisoformat(released)).days if len(released) == 10 else 99
            badges[rel.id] = f"nové {kind}" if days <= 7 else kind
        s.commit()
    _save(user_id, "release_radar", {"title": "Novinky od tvých interpretů", "kind": "albums", "ids": ids[:20], "badges": badges})
    return len(ids)


# ----------------------------------------------------------------------
# Méně známé skladby
# ----------------------------------------------------------------------

async def build_deep_cuts(user_id: str) -> int:
    """Skladby tvých oblíbených interpretů, které nejsou mezi jejich hity
    (Last.fm pořadí 12.-60.) a které jsi ještě neslyšel -- 2 od interpreta,
    denně jiné."""
    from app.catalog import lastfm
    from app.download_match import MARKERS, tokens
    from app.tags import _resolve_tracks

    weights, names = await asyncio.to_thread(_artist_weights, user_id, 180, 45.0)
    # Vlastní interpret podle jména na Last.fm = cizí kapela.
    top = [a for a, _w in weights.most_common(20) if a in names and not is_own_artist(a)]
    with Session(engine) as s:
        heard = defaultdict(set)
        for artist_id, title in s.exec(
            select(Recording.artist_id, Recording.title)
            .join(Listen, Listen.recording_id == Recording.id)
            .where(Listen.user_id == user_id, Recording.artist_id.in_(top))  # type: ignore[attr-defined]
        ).all():
            heard[artist_id].add(_normalize(title))
    rng = random.Random(f"deep:{user_id}:{utcnow().date().isoformat()}")
    sem = asyncio.Semaphore(5)

    async def cuts(artist_id: str) -> list[dict]:
        async with sem:
            # Celé jméno ("Angus & Julia Stone" -- ne jen "Angus", jiná kapela),
            # jen "AURORA;Pomme" -> první.
            tracks = await lastfm.artist_top_tracks(names[artist_id].split(";")[0].strip(), 60)
        # Jen studiové skladby: bez živáků, remixů, dem a "Album Version"
        # duplikátů hitů (Last.fm je vede jako zvláštní skladby).
        pool = [
            t for t in tracks[11:60]
            if _normalize(t["title"]) not in heard[artist_id]
            and not (set(tokens(t["title"])) & (MARKERS | {"version", "verze", "edit", "mix"}))
        ]
        rng.shuffle(pool)
        return pool[:3]

    items = [t for group in await asyncio.gather(*(cuts(a) for a in top)) for t in group]
    rng.shuffle(items)
    ids = (await _resolve_tracks(items, 40))[:36]
    if len(ids) < 8:
        _clear(user_id, "deep_cuts")
        return 0
    pid = _save_playlist(user_id, "personal:deep-cuts", "Méně známé od tvých oblíbených", "Skladby mimo hity tvých nejposlouchanějších interpretů, které jsi ještě neslyšel", ids, timedelta(days=1))
    _save(user_id, "deep_cuts", {"title": "Méně známé skladby", "kind": "tracks", "ids": ids[:20], "playlistId": pid})
    return len(ids)


# ----------------------------------------------------------------------
# Interpreti, které bys mohl znát / Celá alba pro tebe
# ----------------------------------------------------------------------

async def _similar_unknown(user_id: str, top_n: int = 15) -> tuple[list[str], set[str], list[str]]:
    """(podobní interpreti, které neposloucháš -- seřazení, známá jména, top interpreti)."""
    from app.home import lastfm_taste as lt

    weights, names = await asyncio.to_thread(_artist_weights, user_id, 365, 90.0)
    with Session(engine) as s:
        all_known = {
            _normalize(n)
            for n in s.exec(
                select(Artist.name).join(Recording, Recording.artist_id == Artist.id).join(Listen, Listen.recording_id == Recording.id).where(Listen.user_id == user_id)
            ).all()
        }
    # Bez vlastních interpretů -- Last.fm zná jen stejnojmennou cizí kapelu.
    top = [names[a] for a, _w in weights.most_common(top_n) if a in names and not is_own_artist(a)]
    score: Counter = Counter()
    display: dict[str, str] = {}
    seeds: dict[str, Counter] = defaultdict(Counter)  # návrh -> od kterých tvých interpretů
    for rank, name in enumerate(top):
        for other, match in (await lt.similar_artist_names(name, 30))[:12]:
            k = _normalize(other)
            if k in all_known:
                continue
            score[k] += match * (1.0 - rank / (top_n * 1.5))
            seeds[k][name] += match
            display.setdefault(k, other)
    # Pestrost: nejvýš 3 návrhy, jejichž hlavní zdroj je stejný tvůj interpret
    # (jinak by jeden metalový interpret přinesl půlku řady).
    per_seed: Counter = Counter()
    ranked = []
    for k, _s in score.most_common(120):
        main = seeds[k].most_common(1)[0][0]
        if per_seed[main] >= 3:
            continue
        per_seed[main] += 1
        ranked.append(display[k])
    return ranked[:40], all_known, top


async def build_artist_discovery(user_id: str) -> int:
    """Interpreti podobní těm, které posloucháš nejvíc (Last.fm), které jsi
    ještě neposlouchal -- podobní víc tvým oblíbeným = výš."""
    from app import browse

    ranked, _known, _top = await _similar_unknown(user_id)
    ids = await browse._resolve_artists(ranked, 14, set())
    _save(user_id, "artist_discovery", {"title": "Interpreti, které bys mohl znát", "kind": "artists", "ids": ids})
    return len(ids)


async def build_album_picks(user_id: str) -> int:
    """Celá alba k poslechu od začátku do konce: nejlepší album podobných
    interpretů, které neznáš, střídavě s nejoblíbenějšími alby tvých
    interpretů, která jsi ještě neslyšel."""
    from app import browse
    from app.catalog import lastfm

    ranked, _known, top = await _similar_unknown(user_id)
    with Session(engine) as s:
        heard_albums = {
            _normalize(t)
            for t in s.exec(
                select(Release.title).join(Recording, Recording.release_id == Release.id).join(Listen, Listen.recording_id == Recording.id).where(Listen.user_id == user_id)
            ).all()
        }
    sem = asyncio.Semaphore(5)

    async def best(name: str, n: int) -> list[dict[str, str]]:
        async with sem:
            albums = await lastfm.top_albums(name, n)
        return [{"artist": name, "title": a["title"]} for a in albums if _normalize(a["title"]) not in heard_albums and a.get("title")]

    new_artists = [a[:1] for a in await asyncio.gather(*(best(n, 2) for n in ranked[:10]))]
    own_artists = [a[:1] for a in await asyncio.gather(*(best(n, 6) for n in top[:10]))]
    items: list[dict[str, str]] = []
    for pair in zip(new_artists, own_artists):
        for group in pair:
            items += group
    ids = await browse._resolve_albums(items, 14)
    _save(user_id, "album_picks", {"title": "Celá alba pro tebe", "kind": "albums", "ids": ids})
    return len(ids)


# ----------------------------------------------------------------------
# SoundCloud
# ----------------------------------------------------------------------

async def build_soundcloud(user_id: str) -> int:
    """Skladby z oficiálních SoundCloud profilů tvých interpretů, které nejsou
    v jejich diskografii (dema, živáky, remixy) -- nejnovější 2 od každého."""
    from app import soundcloud
    from app.catalog.deezer_ingest import version_key
    from app.catalog.musicbrainz import get_musicbrainz_client

    weights, names = await asyncio.to_thread(_artist_weights, user_id, 365, 90.0)
    top = [a for a, _w in weights.most_common(30) if a in names]
    mb = get_musicbrainz_client()
    ids: list[str] = []
    for artist_id in top:
        with Session(engine) as s:
            artist = s.get(Artist, artist_id)
            mbid = artist.mbid if artist else None
            manual = (artist.external_refs or {}).get("soundcloud") if artist else None
        relations: list = []
        if not manual and mbid and not mbid.startswith("own:"):
            try:
                relations = (await mb.get_artist(mbid)).get("relations") or []
            except Exception:  # noqa: BLE001
                relations = []
        with Session(engine) as s:
            profile = soundcloud.artist_profile(s, artist_id, relations)
        if not profile:
            continue
        items = await soundcloud.profile_tracks(profile, 20)
        taken = 0
        with Session(engine) as s:
            artist = s.get(Artist, artist_id)
            official = soundcloud.official_titles(s, artist_id)
            for item in items:
                title = soundcloud.clean_title(item["title"], artist.name)
                if version_key(title) in official or (item.get("duration") and item["duration"] < 60):
                    continue
                rec = soundcloud.recording_for(s, artist, {**item, "title": title})
                s.flush()
                if (rec.external_refs or {}).get("soundcloudPreviewOnly"):
                    continue  # jen 30s ukázka (Go+), plnou verzi nestáhneme
                ids.append(rec.id)
                taken += 1
                if taken >= 2:
                    break
            s.commit()
        if len(ids) >= 30:
            break
    if not ids:
        _clear(user_id, "soundcloud")
        return 0
    random.Random(f"sc:{user_id}:{utcnow().date().isoformat()}").shuffle(ids)
    pid = _save_playlist(user_id, "personal:soundcloud", "Na SoundCloudu", "Dema, živáky a remixy z oficiálních SoundCloud profilů tvých interpretů", ids, timedelta(days=1))
    _save(user_id, "soundcloud", {"title": "Na SoundCloudu od tvých interpretů", "kind": "tracks", "ids": ids[:20], "playlistId": pid})
    return len(ids)


# ----------------------------------------------------------------------
# Živé sekce: Shazam, rodina
# ----------------------------------------------------------------------

def shazam_ids(session: Session, user_id: str) -> list[str]:
    """Co sis rozpoznal v Shazamu -- neposlechnuté napřed, pak nejnovější."""
    rows = session.exec(
        select(ListenLater).where(ListenLater.user_id == user_id, ListenLater.source == "shazam", ListenLater.kind == "track")
    ).all()
    rows.sort(key=lambda r: (r.listened_at is not None, -_aware(r.added_at).timestamp()))
    return [r.target_id for r in rows][:30]


def share_key(user_id: str) -> str:
    return f"share_listening:{user_id}"


def shares_listening(session: Session, user_id: str) -> bool:
    row = session.get(HomeSnapshot, share_key(user_id))
    return bool(row and (row.payload or {}).get("on"))


def family_sections(session: Session, user_id: str) -> list[dict[str, Any]]:
    """Pro každý jiný profil, který sdílení povolil: jeho poslední poslechy
    (14 dní, bez opakování)."""
    out = []
    for other in session.exec(select(AppUser).where(AppUser.id != user_id)).all():
        if not shares_listening(session, other.id):
            continue
        rows = session.exec(
            select(Listen.recording_id)
            .where(Listen.user_id == other.id, Listen.played_at >= utcnow() - timedelta(days=14))
            .order_by(Listen.played_at.desc())  # type: ignore[attr-defined]
            .limit(200)
        ).all()
        ids = list(dict.fromkeys(rows))[:20]
        if ids:
            out.append({"id": f"family_{other.id[:8]}", "title": f"{other.name} poslouchá", "ids": ids})
    return out


# ----------------------------------------------------------------------
# Registr, sestavení, vykreslení
# ----------------------------------------------------------------------

SPECS: list[Spec] = [
    Spec("now_mix", "Mix na teď", timedelta(hours=1), build_now_mix),
    Spec("year_ago", "Tento týden před rokem", timedelta(hours=12), build_year_ago),
    Spec("forgotten", "Zapomenuté poklady", timedelta(days=1), build_forgotten),
    Spec("unfinished", "Dokonči album", timedelta(hours=6), build_unfinished),
    Spec("anniversaries", "Výročí alb", timedelta(hours=12), build_anniversaries),
    Spec("release_radar", "Novinky od tvých interpretů", timedelta(days=1), build_release_radar),
    Spec("deep_cuts", "Méně známé skladby", timedelta(days=1), build_deep_cuts),
    Spec("artist_discovery", "Interpreti, které bys mohl znát", timedelta(days=1), build_artist_discovery),
    Spec("album_picks", "Celá alba pro tebe", timedelta(days=1), build_album_picks),
    Spec("shazam", "Z tvého Shazamu", timedelta(hours=1), None),
    Spec("soundcloud", "Na SoundCloudu od tvých interpretů", timedelta(days=1), build_soundcloud),
    Spec("family", "Co poslouchá rodina", timedelta(hours=1), None),
]
_BY_ID = {s.id: s for s in SPECS}


def _fresh(user_id: str, spec: Spec) -> bool:
    with Session(engine) as s:
        row = s.get(HomeSnapshot, key(spec.id, user_id))
        return bool(row and row.generated_at and utcnow() - _aware(row.generated_at) < spec.ttl)


async def build_now(user_id: str, section_ids: list[str], *, force: bool = True) -> None:
    for sid in section_ids:
        spec = _BY_ID.get(sid)
        if spec is None or spec.build is None:
            continue
        if not force and _fresh(user_id, spec):
            continue
        try:
            n = await spec.build(user_id)
            logger.info("sekce %s pro %s: %d položek", sid, user_id[:8], n)
        except Exception:  # noqa: BLE001 - jedna sekce nesmí shodit ostatní
            logger.exception("sekce %s pro %s selhala", sid, user_id[:8])


async def build_enabled() -> int:
    """Běh na pozadí (registr Domů): zapnuté sekce aktuálního profilu, které
    jsou starší než jejich TTL."""
    from app.home import generators as g
    from app.home.service import section_enabled

    user_id = g.home_user()
    wanted = [s.id for s in SPECS if s.build is not None and section_enabled(user_id, s.id)]
    await build_now(user_id, wanted, force=False)
    return len(wanted)


def render(session: Session, user_id: str, section_id: str) -> list[dict[str, Any]]:
    """Sekce pro GET /home (jen čtení snapshotu / rychlý dotaz)."""
    from app import browse
    from app.home.service import AlbumCardOut, _recording_out

    def tracks(ids: list[str]) -> list[dict]:
        out = []
        for rid in ids:
            rec = session.get(Recording, rid)
            if rec is not None:
                out.append(_recording_out(session, rec).model_dump(mode="json", by_alias=True))
        return out

    if section_id == "shazam":
        items = tracks(shazam_ids(session, user_id))
        return [{"id": "shazam", "title": "Z tvého Shazamu", "type": "track_rail", "items": items}] if items else []
    if section_id == "family":
        return [
            {"id": f["id"], "title": f["title"], "type": "track_rail", "items": tracks(f["ids"])}
            for f in family_sections(session, user_id)
        ]
    row = session.get(HomeSnapshot, key(section_id, user_id))
    data = (row.payload or {}) if row else {}
    ids = data.get("ids") or []
    if not ids:
        return []
    title = data.get("title") or _BY_ID[section_id].title
    kind = data.get("kind")
    if kind == "tracks":
        items = tracks(ids)
        sec = {"id": section_id, "title": title, "type": "track_rail", "items": items}
        if data.get("playlistId"):
            sec["playlistId"] = data["playlistId"]
        return [sec] if items else []
    if kind == "albums":
        badges = data.get("badges") or {}
        items = []
        for rid in ids:
            rel = session.get(Release, rid)
            if rel is None:
                continue
            artist = session.get(Artist, rel.artist_id)
            card = AlbumCardOut(
                id=rel.id, title=rel.title, artist_id=rel.artist_id, artist_name=artist.name if artist else None,
                release_date=rel.release_date, release_type=rel.release_type, images=rel.images or [],
            ).model_dump(mode="json", by_alias=True)
            if badges.get(rid):
                card["badge"] = badges[rid]
            items.append(card)
        return [{"id": section_id, "title": title, "type": "album_cards", "items": items}] if items else []
    if kind == "artists":
        from app.library.dislikes import disliked_artist_ids

        bad = disliked_artist_ids(session, user_id)
        items = [browse._artist_card(a) for a in (session.get(Artist, i) for i in ids if i not in bad) if a]
        return [{"id": section_id, "title": title, "type": "artist_cards", "items": items}] if items else []
    return []
