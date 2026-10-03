"""Soundtracky v Procházet -- jako hudba, ne zvláštní svět:

- soundtrack filmu/hry = ALBUM (Original Score, Soundtrack s písněmi),
- franšíza (Zaklínač, Harry Potter, GTA) = stránka jako INTERPRET: oblíbené
  skladby, diskografie soundtracků všech dílů, skladatelé, rádia,
- Soundtracky / Hry / Filmy / Seriály / Horor... = stránky jako ŽÁNRY.

Data: ručně vybrané díla (app/games.py, app/movies.py) + cokoli z Wikidat
(app/works.py). Skladatelé jsou běžní interpreti.
"""

from __future__ import annotations

import asyncio
import logging
from datetime import date
from typing import Any

from sqlmodel import Session

from app.catalog.cache import cached_json
from app.db import engine

logger = logging.getLogger("vault.soundtracks")

DAY = 24 * 3600

# podkategorie -> (název, popis, (catalog "games"/"movies"), štítky děl (prázdné = vše), mixy katalogu)
SUBCATS: dict[str, dict[str, Any]] = {
    "games": {
        "title": "Hry", "ns": "games", "tags": (), "mixes": ("boss", "explore", "retro", "epic", "indie", "czech"),
        "about": "Hudba z videoher -- od 8bitových melodií Nintenda po orchestrální eposy Skyrimu a Zaklínače.",
    },
    "movies": {
        "title": "Filmy a seriály", "ns": "movies", "tags": (), "mixes": ("epic", "classic", "fantasy", "roadtrip", "tv", "horror", "animated", "czech"),
        "about": "Filmová a seriálová hudba -- Williams, Zimmer, Shore, Morricone, Djawadi a soundtracky, které znáš z kina.",
    },
    "tv": {
        "title": "Seriály", "ns": "movies", "tags": ("tv",), "mixes": ("tv",),
        "about": "Znělky a hudba seriálů -- Hra o trůny, Stranger Things, Twin Peaks, The Last of Us.",
    },
    "anime": {
        "title": "Anime a Ghibli", "ns": "movies", "tags": ("animated",), "mixes": ("animated",),
        "about": "Animované filmy a seriály -- Joe Hisaishi a Studio Ghibli, Lví král, Arcane.",
    },
    "horror": {
        "title": "Horor a napětí", "ns": "movies", "tags": ("horror", "thriller"), "mixes": ("horror",),
        "about": "Napětí a strach -- Psycho, Halloween, Osvícení, Suspiria, Temný rytíř.",
    },
    "film-classics": {
        "title": "Klasika filmové hudby", "ns": "movies", "tags": ("classic",), "mixes": ("classic",),
        "about": "Velká témata filmové historie -- Kmotr, Hvězdné války, Čelisti, Tenkrát na Západě.",
    },
    "game-radio": {
        "title": "Herní rádia", "ns": "games", "tags": (), "stations_only": True, "mixes": (),
        "about": "Rádia z her -- všechny stanice GTA od Liberty City po Los Santos.",
    },
}


def _catalog(ns: str):
    from app import games
    from app.movies import MOVIES_CATALOG

    return games.GAMES_CATALOG if ns == "games" else MOVIES_CATALOG


def _works(sub: str | None) -> list[tuple[Any, Any]]:
    """(dílo, katalog) podkategorie (None = vše)."""
    out = []
    for key in (["games", "movies"] if sub is None else [SUBCATS[sub]["ns"]]):
        cat = _catalog(key)
        for item in cat.items:
            if sub is not None:
                spec = SUBCATS[sub]
                if spec.get("stations_only") and not item.stations:
                    continue
                if spec["tags"] and not set(spec["tags"]) & set(item.tags):
                    continue
                if set(spec.get("exclude", ())) & set(item.tags):
                    continue
            out.append((item, cat))
    return out


def _album_cards(session: Session, ids: list[str]) -> list[dict[str, Any]]:
    from app import browse
    from app.models import Release

    out, seen = [], set()
    for rid in ids:
        rel = session.get(Release, rid)
        if rel is not None and rel.id not in seen:
            seen.add(rel.id)
            out.append(browse._album_card(session, rel))
    return out


async def category_extra(category_id: str) -> dict[str, Any]:
    """Obsah stránky Soundtracky / podkategorie ve tvaru stránky žánru."""
    from app import browse, games

    sub = category_id

    async def build() -> dict[str, Any]:
        works = _works(sub)
        cards: list[tuple[dict[str, Any], Any, Any]] = []
        sem = asyncio.Semaphore(6)

        async def one(item, cat):
            async with sem:
                return await games.game_card(item, cat), item, cat

        cards = list(await asyncio.gather(*(one(i, c) for i, c in works)))
        this_year = date.today().year
        by_year = sorted(cards, key=lambda t: -t[0]["year"])
        album_ids = [a["id"] for card, _i, _c in by_year for a in card.get("albums") or []]
        new_ids = [a["id"] for card, _i, _c in by_year if card["year"] >= this_year - 2 for a in card.get("albums") or []]

        # Franšízy podkategorie (série s aspoň dvěma díly, nebo s rádii).
        franchises = []
        seen: set[str] = set()
        for card, item, cat in by_year:
            sid = item.series
            if not sid or sid in seen:
                continue
            members = [c for c, i, _ in cards if i.series == sid]
            if len(members) < 2 and not item.stations:
                continue
            seen.add(sid)
            title = cat.series.get(sid, (sid, ""))[0]
            franchises.append({"id": sid, "title": title, "image": card["hero"] or card["cover"], "count": len(members)})

        # Mixy: naše herní/filmové mixy (u Herních rádií rádia GTA).
        mix_ids: list[str] = []
        keys = ["games", "movies"] if sub is None else [SUBCATS[sub]["ns"]]
        for key in keys:
            page = await games.page(_catalog(key))
            wanted = (SUBCATS[sub]["mixes"] if sub else tuple(page.get("mixIds") or {}))
            mix_ids += [pid for mid, pid in (page.get("mixIds") or {}).items() if mid in wanted]
        if sub == "game-radio":
            for item, _cat in works:
                mix_ids += await games.stations(item)

        composers: list[str] = []
        for item, _cat in works:
            for c in item.composers[:1]:
                if c and c != "Various Artists" and c not in composers:
                    composers.append(c)
        composer_ids = await browse._resolve_artists(composers, 24, set())

        return {
            "albumIds": album_ids,
            "newIds": new_ids[:20],
            "franchises": franchises,
            "mixIds": mix_ids,
            "composerIds": composer_ids,
        }

    data = await cached_json(f"soundtracks:cat:v2:{category_id}", DAY // 2, build, is_empty=lambda v: not v.get("albumIds") and not v.get("mixIds"))
    from app.home.service import _card
    from app.models import Artist, Playlist

    with Session(engine) as session:
        mixes = [
            _card(session, p).model_dump(mode="json", by_alias=True)
            for p in (session.get(Playlist, pid) for pid in data.get("mixIds") or [])
            if p is not None
        ]
        out = {
            "mixes": mixes,
            "classics": _album_cards(session, data.get("albumIds") or []),
            "newReleases": _album_cards(session, data.get("newIds") or []),
            "topArtists": [
                browse._artist_card(a) for a in (session.get(Artist, i) for i in data.get("composerIds") or []) if a
            ],
            "franchises": data.get("franchises") or [],
            "about": SUBCATS[sub]["about"],
            "aboutSource": None,
        }
    subs = [
        {"id": c.id, "title": c.title, "group": c.group, "color": c.color, "icon": c.icon}
        for c in browse.CATEGORIES
        if c.parent == category_id
    ]
    if subs:
        out["subcategories"] = subs
    return out


async def franchise(franchise_id: str) -> dict[str, Any] | None:
    """Franšíza jako interpret: díla, soundtracky (diskografie), skladatelé,
    rádia, playlist se vším."""
    from app import browse, games, works
    from app.movies import MOVIES_CATALOG

    if works.is_qid(franchise_id):
        page = await games.work_series_page(franchise_id)
        cat = games.catalog_for("game" if (page or {}).get("base") == "games" else "film")
    elif franchise_id in games.SERIES:
        page, cat = await games.series_page(franchise_id), games.GAMES_CATALOG
    elif franchise_id in MOVIES_CATALOG.series:
        page, cat = await games.series_page(franchise_id, MOVIES_CATALOG), MOVIES_CATALOG
    else:
        return None
    if not page:
        return None
    cards = page.get("games") or []
    composers: list[str] = []
    for card in cards:
        for c in card.get("composers") or []:
            if c and c != "Various Artists" and c not in composers:
                composers.append(c)
    composer_ids = await browse._resolve_artists(composers, 12, set())
    from app.home.service import _card
    from app.models import Artist, Playlist

    with Session(engine) as session:
        albums = _album_cards(session, [a["id"] for card in reversed(cards) for a in card.get("albums") or []])
        stations = [
            _card(session, p).model_dump(mode="json", by_alias=True)
            for p in (session.get(Playlist, pid) for pid in page.get("stationIds") or [])
            if p is not None
        ]
        artists = [browse._artist_card(a) for a in (session.get(Artist, i) for i in composer_ids) if a]
    latest = next((c for c in reversed(cards) if c.get("hero")), None)
    return {
        "id": franchise_id,
        "title": page.get("title"),
        "image": latest["hero"] if latest else None,
        "cover": latest["cover"] if latest else None,
        "kind": "games" if cat.ns == "games" else "movies",
        "workCount": len(cards),
        "years": [c["year"] for c in cards if c.get("year")],
        "playlistId": page.get("playlistId"),
        "albums": albums,
        "stations": stations,
        "composers": artists,
    }
