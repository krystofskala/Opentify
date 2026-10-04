"""Živé úvodní stránky Herní soundtracky / Filmy a seriály -- jako zbytek
appky: denně se obměňují a rozšiřují, "Pro tebe" podle poslechu.

Zdroje (bez účtů a klíčů):
- Steam: nejhranější a nejprodávanější hry (veřejné API),
- Wikidata (SPARQL): nové, klasika, indie, retro, horor, seriály, české,
  franšízy -- seřazené podle oblíbenosti (počet jazykových verzí článku),
- Apple iTunes (přes Mullvad proxy): plakáty filmů a seriálů ve vysokém
  rozlišení.

Ruční výběr (app/games.py, app/movies.py) zůstává jako základ kvality. Každé
dílo projde stejnými pravidly (správný soundtrack, obrázek), jinak se neukáže.
Sestavuje se denně na pozadí (registr Domů); stránka jen čte.
"""

from __future__ import annotations

import os

import asyncio
import logging
import random
from collections import Counter
from datetime import date, timedelta
from typing import Any

import httpx
from sqlmodel import Session, select

from app.catalog.cache import cached_json
from app.db import engine
from app.download_match import _covered, fold, tokens

logger = logging.getLogger("vault.soundtrack_discovery")

DAY = 24 * 3600
MONTH = 30 * DAY
# Identifikace pro Wikipedii/Steam -- z .env (MUSICBRAINZ_USER_AGENT), ať se
# cizí instalace nehlásí cizím kontaktem.
_UA = {"User-Agent": os.environ.get("MUSICBRAINZ_USER_AGENT") or "Opentify/1.0"}
WD_SPARQL = "https://query.wikidata.org/sparql"
DYN_VERSION = "v3"


# ----------------------------------------------------------------------
# Zdroje
# ----------------------------------------------------------------------


async def _sparql(query: str, key: str) -> list[str]:
    """QID výsledků (`?item`) v pořadí dotazu, týden v cache."""

    async def fetch() -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=120.0, headers={**_UA, "Accept": "application/sparql-results+json"}) as client:
            r = await client.get(WD_SPARQL, params={"query": query, "format": "json"})
        rows = ((r.json() if r.status_code == 200 else {}).get("results") or {}).get("bindings") or []
        ids: list[str] = []
        for row in rows:
            qid = (row.get("item") or {}).get("value", "").rsplit("/", 1)[-1]
            if qid and qid not in ids:
                ids.append(qid)
        return {"ids": ids}

    try:
        return (await cached_json(f"wd:q:{DYN_VERSION}:{key}", 7 * DAY, fetch, is_empty=lambda v: not v.get("ids"))).get("ids") or []
    except Exception:  # noqa: BLE001
        logger.exception("wikidata %s", key)
        return []


def _q(types: str, where: str, order: str = "DESC(?links)", limit: int = 40) -> str:
    return (
        "SELECT DISTINCT ?item ?links WHERE { VALUES ?type { %s } ?item wdt:P31 ?type . %s "
        "?item wikibase:sitelinks ?links . } ORDER BY %s LIMIT %d" % (types, where, order, limit)
    )


_FILM = "wd:Q11424"
_TV = "wd:Q5398426"
_GAME = "wd:Q7889"


# Datum PRVNÍHO vydání (re-edice mají ve Wikidatech další P577 -- Interstellar
# by jinak byl "nový").
def _first_after(year: int) -> str:
    return "?item wdt:P577 ?d . FILTER(YEAR(?d) >= %d) FILTER NOT EXISTS { ?item wdt:P577 ?d0 . FILTER(?d0 < ?d) }" % year


def _first_before(year: int) -> str:
    return "?item wdt:P577 ?d . FILTER(YEAR(?d) < %d) FILTER NOT EXISTS { ?item wdt:P577 ?d0 . FILTER(?d0 < ?d) }" % year


def _queries(ns: str) -> dict[str, str]:
    y = date.today().year
    if ns == "games":
        return {
            "new": _q(_GAME, _first_after(y - 2)),
            "indie": _q(_GAME, "?item wdt:P136 wd:Q2762504 ."),
            "retro": _q(_GAME, _first_before(2000) + " ?item wdt:P86 ?c ."),
            "czech": _q(_GAME, "?item wdt:P495 wd:Q213 .", limit=30),
            "series": _q("wd:Q7058673", "", limit=24),
        }
    return {
        "popular": _q(_FILM, _first_after(y - 3) + " ?item wdt:P86 ?c ."),
        "new": _q(f"{_FILM} {_TV}", _first_after(y - 1), limit=30),
        "classic": _q(_FILM, _first_before(2000) + " ?item wdt:P86 ?c .", limit=50),
        "tv": _q(_TV, "?item wdt:P86 ?c ."),
        "horror": _q(_FILM, "?item wdt:P136 wd:Q200092 . ?item wdt:P86 ?c ."),
        # Původní jazyk čeština -- ne zahraniční filmy natáčené v Česku.
        "czech": _q(_FILM, "?item wdt:P364 wd:Q9056 . ?item wdt:P495 wd:Q213 . ?item wdt:P86 ?c . "
                           "FILTER NOT EXISTS { ?item wdt:P364 wd:Q1860 }", limit=40),
        "series": _q("wd:Q24856", "", limit=24),
    }


async def _steam_popular() -> list[int]:
    """Nejhranější + nejprodávanější hry na Steamu (app id)."""

    async def fetch() -> dict[str, Any]:
        ids: list[int] = []
        async with httpx.AsyncClient(timeout=20.0, headers=_UA) as client:
            try:
                r = await client.get("https://api.steampowered.com/ISteamChartsService/GetMostPlayedGames/v1/")
                for row in ((r.json() or {}).get("response") or {}).get("ranks") or []:
                    if row.get("appid"):
                        ids.append(int(row["appid"]))
            except (httpx.HTTPError, ValueError):
                pass
            try:
                r = await client.get("https://store.steampowered.com/api/featuredcategories", params={"cc": "cz", "l": "english"})
                for item in ((r.json() or {}).get("top_sellers") or {}).get("items") or []:
                    if item.get("id") and int(item["id"]) not in ids:
                        ids.append(int(item["id"]))
            except (httpx.HTTPError, ValueError):
                pass
        return {"ids": ids[:60]}

    return (await cached_json("steam:popular:v1", DAY, fetch, is_empty=lambda v: not v.get("ids"))).get("ids") or []


async def _steam_indie() -> list[int]:
    """Uznávané indie hry: štítek Indie na Steamu (SteamSpy, bez klíče), jen
    s aspoň 93 % kladných recenzí a hodně hráči (Stardew, Hollow Knight...)."""

    async def fetch() -> dict[str, Any]:
        try:
            async with httpx.AsyncClient(timeout=60.0, headers=_UA) as client:
                r = await client.get("https://steamspy.com/api.php", params={"request": "tag", "tag": "Indie"})
            games = list((r.json() or {}).values())
        except (httpx.HTTPError, ValueError):
            return {}
        good = []
        for g in games:
            pos, neg = int(g.get("positive") or 0), int(g.get("negative") or 0)
            if pos >= 15000 and pos / max(1, pos + neg) >= 0.93:
                good.append((pos, int(g["appid"])))
        return {"ids": [a for _p, a in sorted(good, reverse=True)[:60]]}

    return (await cached_json("steamspy:indie:v1", 7 * DAY, fetch, is_empty=lambda v: not v.get("ids"))).get("ids") or []


async def _qids_for_steam(app_ids: list[int]) -> list[str]:
    if not app_ids:
        return []
    values = " ".join(f'"{a}"' for a in app_ids)
    query = "SELECT ?item ?appid WHERE { VALUES ?appid { %s } ?item wdt:P1733 ?appid . }" % values
    found = await _sparql(query, "steam:" + ",".join(map(str, app_ids[:60])))
    return found


async def apple_artwork(title: str, year: int, kind: str) -> str | None:
    """Plakát filmu / obal seriálu z iTunes (přes proxy), ve vysokém rozlišení."""
    from app.apple_http import apple_http

    client = apple_http()
    if client is None:
        return None
    entity = "movie" if kind == "film" else "tvSeason"

    async def fetch() -> dict[str, Any]:
        try:
            r = await client.get("https://itunes.apple.com/search", params={"term": title, "entity": entity, "limit": 10, "country": "us"})
            results = (r.json() or {}).get("results") or []
        except (httpx.HTTPError, ValueError):
            return {}
        want = set(tokens(title)) - {"the", "a", "of"}
        for item in results:
            name = item.get("trackName") or item.get("collectionName") or ""
            words = set(tokens(name))
            if not want or not all(_covered(w, words) for w in want):
                continue
            released = (item.get("releaseDate") or "")[:4]
            if kind == "film" and year and released.isdigit() and abs(int(released) - year) > 1:
                continue
            art = item.get("artworkUrl100") or ""
            if art:
                return {"url": art.replace("100x100bb", "1500x1500bb")}
        return {}

    try:
        apple_url = (await cached_json(f"apple:art:v1:{kind}:{fold(title)}:{year}", MONTH, fetch, is_empty=lambda v: not v.get("url"))).get("url")
    except Exception:  # noqa: BLE001
        return None
    if not apple_url:
        return None
    return await _local_poster(client, apple_url, f"{kind}:{fold(title)}:{year}")


async def _local_poster(client: httpx.AsyncClient, apple_url: str, key: str) -> str | None:
    """Plakát se stáhne jednou (přes proxy) a servíruje z vlastního serveru --
    telefon se k Apple CDN nepřipojí se svou IP. Nepovede-li se, raději žádný
    plakát než únik."""
    import uuid

    from app.catalog.embedded_art import URL_TEMPLATE, _save_resized, artwork_path

    # Pevné UUID z klíče: route artwork bere jen UUID a stejné dílo = stejný soubor.
    poster_id = str(uuid.uuid5(uuid.NAMESPACE_URL, f"opentify:apple-poster:{key}"))
    dest = artwork_path(poster_id)
    if dest.exists():
        return URL_TEMPLATE.format(release_id=poster_id)
    try:
        r = await client.get(apple_url, follow_redirects=True)
        r.raise_for_status()
        data = r.content
    except httpx.HTTPError:
        return None
    if not data or len(data) > 10 * 1024 * 1024:
        return None
    # Hero přes celou šířku -- víc než 600 px běžných obalů.
    if not await asyncio.to_thread(_save_resized, data, dest, 1200):
        return None
    return URL_TEMPLATE.format(release_id=poster_id)


# ----------------------------------------------------------------------
# Denní sestavení
# ----------------------------------------------------------------------


async def _work_cards(qids: list[str], ns: str, tag: str) -> list[dict[str, Any]]:
    """QID -> karty děl (jen se soundtrackem a obrázkem)."""
    from app import games, works

    ents = await works.entities(qids)
    items = []
    for qid in qids:
        entity = ents.get(qid)
        kind = works.kind_of(entity) if entity else None
        if kind is None or (ns == "games") != (kind == "game"):
            continue
        work = await works.to_work(entity)
        items.append((work, kind))
    cat = games.catalog_for("game" if ns == "games" else "film")
    sem = asyncio.Semaphore(2)

    async def one(item):
        work, kind = item
        async with sem:
            try:
                card = await games.game_card(work, cat)
            except Exception:  # noqa: BLE001
                logger.exception("karta %s", work.slug)
                return None
            if kind != "game" and work.title:
                poster = await apple_artwork(work.title, work.year, kind)
                if poster:
                    card = {**card, "cover": poster, "hero": poster, "poster": True}
            if not card.get("albums") or not card.get("cover"):
                return None
            return {**card, "kind": kind, "tags": [tag], "series": work.series, "seriesTitle": work.series_title}

    return [c for c in await asyncio.gather(*(one(i) for i in items)) if c]


async def _series_tiles(qids: list[str]) -> list[dict[str, Any]]:
    """Franšízy z Wikidat -- jen ty, kde mají aspoň 2 díla opravdu soundtrack
    (stránka franšízy pak není prázdná). Obrázek = nejnovější díl."""
    from app import games, works

    ents = await works.entities(qids)
    tiles = []
    for qid in qids[:20]:
        try:
            page = await games.work_series_page(qid)
        except Exception:  # noqa: BLE001
            logger.exception("franšíza %s", qid)
            continue
        cards = (page or {}).get("games") or []
        with_ost = [c for c in cards if c.get("albums")]
        if len(with_ost) < 2:
            continue
        latest = max((c for c in with_ost if c.get("hero")), key=lambda c: c["year"], default=None)
        if latest is None:
            continue
        tiles.append({"id": qid, "title": works._label(ents.get(qid) or {}) or page.get("title"), "count": len(cards), "image": latest["hero"]})
    return tiles


async def build(ns: str) -> dict[str, Any]:
    """Denně na pozadí: řady dynamického katalogu pro `ns` (games/movies)."""
    queries = _queries(ns)
    pools: dict[str, list[dict[str, Any]]] = {}
    if ns == "games":
        steam_qids = await _qids_for_steam(await _steam_popular())
        pools["popular"] = await _work_cards(steam_qids[:40], ns, "popular")
        pools["indie"] = await _work_cards((await _qids_for_steam(await _steam_indie()))[:50], ns, "indie")
    for pool, query in queries.items():
        if pool == "series" or (ns == "games" and pool == "indie"):
            continue
        qids = await _sparql(query, f"{ns}:{pool}:{date.today().isoformat()[:7]}")
        pools[pool] = await _work_cards(qids, ns, pool)
    series = await _series_tiles(await _sparql(queries["series"], f"{ns}:series"))
    data = {"pools": pools, "series": series, "built": date.today().isoformat()}
    with Session(engine) as session:
        from app.models import HomeSnapshot as Snap

        row = session.get(Snap, f"soundtracks:dyn:{ns}") or Snap(key=f"soundtracks:dyn:{ns}")
        row.payload = data
        from app.utils import utcnow

        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    logger.info("soundtracky %s: %s", ns, {k: len(v) for k, v in pools.items()})
    try:
        await write_showcase(ns)
    except Exception:  # noqa: BLE001
        logger.exception("vitrína soundtracků %s", ns)
    return data


async def build_all() -> int:
    n = 0
    for ns in ("games", "movies"):
        try:
            data = await build(ns)
            n += sum(len(v) for v in data["pools"].values())
        except Exception:  # noqa: BLE001
            logger.exception("soundtracky %s", ns)
    return n


def _dyn(ns: str) -> dict[str, Any]:
    from app.models import HomeSnapshot

    with Session(engine) as session:
        row = session.get(HomeSnapshot, f"soundtracks:dyn:{ns}")
        data = (row.payload or {}) if row else {}
    # Starší snímky ještě nesou přímé odkazy na Apple CDN -- do přestavby
    # takové karty raději vynechat, ať telefon k Applu nejde se svou IP.
    pools = data.get("pools") or {}
    if any("mzstatic.com" in str(c.get("cover") or "") + str(c.get("hero") or "") for p in pools.values() for c in p):
        data = {**data, "pools": {
            k: [c for c in p if "mzstatic.com" not in str(c.get("cover") or "") + str(c.get("hero") or "")]
            for k, p in pools.items()
        }}
    return data


# ----------------------------------------------------------------------
# Stránka (čte; "Pro tebe" podle profilu)
# ----------------------------------------------------------------------


def _listened(user_id: str) -> tuple[Counter, set[str]]:
    """Interpreti a vydání, které profil za půl roku poslouchal."""
    from app.models import Artist, Listen, Recording
    from app.utils import utcnow

    since = utcnow() - timedelta(days=180)
    artists: Counter = Counter()
    releases: set[str] = set()
    with Session(engine) as session:
        rows = session.exec(
            select(Recording.artist_id, Recording.release_id).join(Listen, Listen.recording_id == Recording.id)
            .where(Listen.user_id == user_id, Listen.played_at >= since)
        ).all()
        for artist_id, release_id in rows:
            if artist_id:
                artists[artist_id] += 1
            if release_id:
                releases.add(release_id)
        names = {a.id: fold(a.name) for a in session.exec(select(Artist).where(Artist.id.in_(list(artists)))).all()}  # type: ignore[attr-defined]
    return Counter({names[a]: c for a, c in artists.items() if a in names}), releases


def _merge(*rows: list[dict[str, Any]], limit: int = 30) -> list[dict[str, Any]]:
    out, seen = [], set()
    for row in rows:
        for c in row:
            key = fold(c.get("title") or "")
            if c["slug"] in seen or key in seen:
                continue
            seen.add(c["slug"])
            seen.add(key)
            out.append(c)
    return out[:limit]


async def landing(ns: str, user_id: str) -> dict[str, Any]:
    from app import browse, games
    from app.movies import MOVIES_CATALOG

    cat = games.GAMES_CATALOG if ns == "games" else MOVIES_CATALOG
    curated = await games.page(cat)
    dyn = _dyn(ns)
    pools: dict[str, list[dict[str, Any]]] = dyn.get("pools") or {}
    curated_cards = (curated.get("rows") or [{}])[-1].get("games") or []
    curated_by_tag = {r["id"]: r["games"] for r in curated.get("rows") or [] if r["id"] != "all"}
    rng = random.Random(f"{ns}:{user_id}:{date.today().isoformat()}")

    def shuffled(cards: list[dict[str, Any]], keep: int = 0) -> list[dict[str, Any]]:
        head, tail = cards[:keep], cards[keep:]
        rng.shuffle(tail)
        return head + tail

    # Pro tebe: díla, jejichž skladatele posloucháš, a díla franšíz, jejichž
    # soundtracky jsi hrál.
    composers_heard, releases_heard = await asyncio.to_thread(_listened, user_id)
    everything = _merge(*pools.values(), curated_cards, limit=10_000)
    heard_series = {
        c.get("series") for c in everything
        if c.get("series") and any(a["id"] in releases_heard for a in c.get("albums") or [])
    }
    def affinity(c: dict[str, Any]) -> float:
        score = sum(composers_heard.get(fold(x), 0) for x in c.get("composers") or [])
        if c.get("series") in heard_series:
            score += 5
        return score
    played = {c["slug"] for c in everything if any(a["id"] in releases_heard for a in c.get("albums") or [])}
    for_you = sorted((c for c in everything if c["slug"] not in played and affinity(c) > 0), key=lambda c: -affinity(c))[:20]

    popular = _merge(pools.get("popular") or [], curated_by_tag.get("new") or [], limit=24)
    rows: list[dict[str, Any]] = [
        {"id": "popular", "title": "Populární teď", "games": popular},
        {"id": "for-you", "title": "Pro tebe", "games": for_you},
    ]
    if ns == "games":
        rows += [
            {"id": "new", "title": "Nové soundtracky", "games": _merge(sorted(pools.get("new") or [], key=lambda c: -c["year"]), curated_by_tag.get("new") or [])},
            {"id": "indie", "title": "Indie klenoty", "games": shuffled(_merge(curated_by_tag.get("indie") or [], pools.get("indie") or []), 6)},
            {"id": "retro", "title": "Legendy 8/16-bit", "games": shuffled(_merge(curated_by_tag.get("retro") or [], pools.get("retro") or []), 6)},
            {"id": "czech", "title": "Česká stopa", "games": _merge(curated_by_tag.get("czech") or [], pools.get("czech") or [])},
        ]
    else:
        rows += [
            {"id": "new", "title": "Nové soundtracky", "games": _merge(sorted(pools.get("new") or [], key=lambda c: -c["year"]), curated_by_tag.get("new") or [])},
            {"id": "classic", "title": "Klasika", "games": shuffled(_merge(curated_by_tag.get("classic") or [], pools.get("classic") or []), 6)},
            {"id": "tv", "title": "Seriály", "games": _merge(pools.get("tv") or [], curated_by_tag.get("tv") or [])},
            {"id": "horror", "title": "Horor a napětí", "games": shuffled(_merge(curated_by_tag.get("horror") or [], pools.get("horror") or []), 6)},
            {"id": "czech", "title": "Česká filmová hudba", "games": _merge(curated_by_tag.get("czech") or [], pools.get("czech") or [])},
        ]
    rows = [r for r in rows if r["games"]]

    heroes = [c for c in popular[:8] + for_you[:6] if c.get("hero")]
    rng.shuffle(heroes)
    heroes = list({c["slug"]: c for c in heroes}.values())[:10] or (curated.get("heroes") or [])

    series = list(curated.get("series") or [])
    known = {fold(s["title"]) for s in series}
    unit = curated.get("seriesUnit") or ""
    for tile in dyn.get("series") or []:
        if fold(tile["title"]) not in known:
            series.append({**tile, "color": ""})

    # Skladatelé: napřed ti, které posloucháš, pak nejčastější.
    counts: Counter = Counter()
    for c in everything:
        for name in (c.get("composers") or [])[:1]:
            if name and name != "Various Artists":
                counts[name] += 1 + 10 * composers_heard.get(fold(name), 0)
    composer_ids = await browse._resolve_artists([n for n, _c in counts.most_common(30)], 24, set())

    return {
        **curated,
        "heroes": heroes,
        "rows": rows,
        "series": series,
        "seriesUnit": unit,
        "composerIds": composer_ids,
        "poster": ns == "movies",
    }


async def write_showcase(ns: str) -> None:
    """Vitrína soundtracků pro Domů (připnuté "Herní soundtracky" / "Filmy a
    seriály"): mixy a soundtracky populárních děl. Snímek, Domů jen čte."""
    from app import games
    from app.models import HomeSnapshot
    from app.movies import MOVIES_CATALOG
    from app.utils import utcnow

    cat = games.GAMES_CATALOG if ns == "games" else MOVIES_CATALOG
    curated = await games.page(cat)
    pools = _dyn(ns).get("pools") or {}
    popular = _merge(pools.get("popular") or [], pools.get("new") or [], limit=12)
    album_ids = [c["albums"][0]["id"] for c in popular if c.get("albums")]
    mix_ids = list((curated.get("mixIds") or {}).values())[:4]
    with Session(engine) as session:
        row = session.get(HomeSnapshot, f"soundtracks:showcase:{ns}") or HomeSnapshot(key=f"soundtracks:showcase:{ns}")
        row.payload = {"mixIds": mix_ids, "albumIds": album_ids}
        row.generated_at = utcnow()
        session.add(row)
        session.commit()


def showcase_items(session: Session, ns: str) -> list[dict[str, Any]]:
    from app import browse
    from app.home.service import _card
    from app.models import HomeSnapshot, Playlist, Release

    row = session.get(HomeSnapshot, f"soundtracks:showcase:{ns}")
    data = (row.payload or {}) if row else {}
    items: list[dict[str, Any]] = []
    for pid in data.get("mixIds") or []:
        pl = session.get(Playlist, pid)
        if pl is not None:
            items.append({"itemType": "playlist", **_card(session, pl).model_dump(mode="json", by_alias=True)})
    for rid in data.get("albumIds") or []:
        rel = session.get(Release, rid)
        if rel is not None:
            items.append({"itemType": "album", "badge": None, **browse._album_card(session, rel)})
    return items
