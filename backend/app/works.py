"""Filmy, seriály a hry odkudkoli -- Wikidata (otevřená databáze za
Wikipedií, bez klíče): hledání podle názvu, skladatel (P86), datum (P577),
série/franšíza (P179), Steam id (P1733), článek na Wikipedii (plakát).
Dílo z Wikidat je `Game` se slug = QID ("Q102225") a jde stejnou cestou jako
ručně vybraná díla (obrázky, soundtracky, stránka díla i série).
"""

from __future__ import annotations

import os

import asyncio
import logging
from typing import Any

import httpx

from app.catalog.cache import cached_json
from app.games import Game

logger = logging.getLogger("vault.works")

WD_API = "https://www.wikidata.org/w/api.php"
WD_SPARQL = "https://query.wikidata.org/sparql"
# Identifikace pro Wikipedii/Steam -- z .env (MUSICBRAINZ_USER_AGENT), ať se
# cizí instalace nehlásí cizím kontaktem.
_UA = {"User-Agent": os.environ.get("MUSICBRAINZ_USER_AGENT") or "Opentify/1.0"}
WEEK = 7 * 24 * 3600
MONTH = 30 * 24 * 3600

# Instance of (P31) -> druh díla.
_GAME = {"Q7889", "Q4393107", "Q21125433", "Q865493"}  # videohra, ...
_TV = {"Q5398426", "Q581714", "Q1259759", "Q526877", "Q117467246", "Q15416", "Q63952888", "Q24856", "Q1366112"}
_FILM = {"Q11424", "Q24869", "Q29168811", "Q202866", "Q506240", "Q24862", "Q229390", "Q17517379", "Q93204", "Q130232"}


def is_qid(value: str) -> bool:
    return len(value) > 1 and value[0] == "Q" and value[1:].isdigit()


async def _get(params: dict[str, Any], key: str, ttl: int = WEEK, transform=None) -> dict[str, Any]:
    async def fetch() -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=15.0, headers=_UA) as client:
            r = await client.get(WD_API, params={**params, "format": "json"})
        data = r.json() if r.status_code == 200 else {}
        return transform(data) if transform and data else data

    return await cached_json(f"wd:{key}", ttl, fetch, is_empty=lambda v: not v)


# Vlastnosti, které z entit opravdu čteme (druh, rok, skladatel, série,
# Steam id). Celá entita má i MB claimů -- cache tak rostla na 375 MB.
_USED_PROPS = ("P31", "P577", "P580", "P86", "P179", "P1733")


def _slim(data: dict[str, Any]) -> dict[str, Any]:
    out: dict[str, Any] = {}
    for qid, ent in (data.get("entities") or {}).items():
        claims = {}
        for prop in _USED_PROPS:
            vals = [
                {"mainsnak": {"datavalue": {"value": ((c.get("mainsnak") or {}).get("datavalue") or {}).get("value")}}}
                for c in (ent.get("claims") or {}).get(prop) or []
            ]
            if vals:
                claims[prop] = vals
        slim = {k: ent[k] for k in ("id", "labels", "sitelinks", "missing") if k in ent}
        slim["claims"] = claims
        out[qid] = slim
    return {"entities": out}


async def entities(ids: list[str]) -> dict[str, dict[str, Any]]:
    out: dict[str, dict[str, Any]] = {}
    for i in range(0, len(ids), 40):
        chunk = ids[i:i + 40]
        data = await _get(
            {"action": "wbgetentities", "ids": "|".join(chunk), "props": "claims|labels|sitelinks",
             "languages": "cs|en", "sitefilter": "enwiki|cswiki"},
            "ent2:" + "|".join(chunk),
            transform=_slim,
        )
        out.update(data.get("entities") or {})
    return out


def _values(entity: dict[str, Any], prop: str) -> list[Any]:
    out = []
    for claim in (entity.get("claims") or {}).get(prop) or []:
        value = ((claim.get("mainsnak") or {}).get("datavalue") or {}).get("value")
        if value is not None:
            out.append(value)
    return out


def kind_of(entity: dict[str, Any]) -> str | None:
    types = {v.get("id") for v in _values(entity, "P31") if isinstance(v, dict)}
    if types & _GAME:
        return "game"
    if types & _TV:
        return "tv"
    if types & _FILM:
        return "film"
    return None


def _label(entity: dict[str, Any]) -> str:
    labels = entity.get("labels") or {}
    label = ((labels.get("en") or labels.get("cs") or {}).get("value")) or ""
    if not label:
        sitelinks = entity.get("sitelinks") or {}
        label = ((sitelinks.get("enwiki") or sitelinks.get("cswiki") or {}).get("title")) or ""
    return label


def _year(entity: dict[str, Any]) -> int:
    years = []
    for v in _values(entity, "P577") + _values(entity, "P580"):
        t = v.get("time") if isinstance(v, dict) else None
        if t and len(t) > 5 and t[1:5].isdigit():
            years.append(int(t[1:5]))
    return min(years) if years else 0


async def to_work(entity: dict[str, Any], composer_names: dict[str, str] | None = None) -> Game:
    composers_ids = [v["id"] for v in _values(entity, "P86") if isinstance(v, dict) and v.get("id")]
    names = composer_names or {}
    missing = [c for c in composers_ids if c not in names]
    if missing:
        ents = await entities(missing)
        names = {**names, **{k: _label(v) for k, v in ents.items()}}
    series = [v["id"] for v in _values(entity, "P179") if isinstance(v, dict) and v.get("id")]
    steam = next((v for v in _values(entity, "P1733") if isinstance(v, str) and v.isdigit()), None)
    sitelinks = entity.get("sitelinks") or {}
    wiki = (sitelinks.get("enwiki") or {}).get("title")
    kind = kind_of(entity)
    series_title = None
    if series:
        series_title = _label((await entities([series[0]])).get(series[0]) or {}) or None
    return Game(
        slug=entity.get("id") or "",
        title=_label(entity),
        year=_year(entity),
        composers=tuple(n for n in (names.get(c) for c in composers_ids) if n) or ("",),
        series=series[0] if series else None,
        steam=int(steam) if steam else None,
        wiki=wiki or _label(entity),
        tags=(kind,) if kind else (),
        series_title=series_title,
    )


async def get(qid: str) -> tuple[Game, str] | None:
    """Dílo podle QID -> (Game, druh "game" / "film" / "tv")."""
    ents = await entities([qid])
    entity = ents.get(qid)
    if not entity or "missing" in entity:
        return None
    kind = kind_of(entity)
    if kind is None:
        return None
    return await to_work(entity), kind


async def search(query: str, limit: int = 10) -> list[tuple[Game, str]]:
    """Hledání filmů, seriálů a her podle názvu (cs i en)."""
    query = (query or "").strip()
    if len(query) < 2:
        return []
    ids: list[str] = []
    for lang in ("en", "cs"):
        data = await _get(
            {"action": "wbsearchentities", "search": query, "language": lang, "uselang": lang, "type": "item", "limit": 20},
            f"search:{lang}:{query.lower()}",
        )
        for hit in data.get("search") or []:
            if hit.get("id") and hit["id"] not in ids:
                ids.append(hit["id"])
    ents = await entities(ids)
    out: list[tuple[Game, str]] = []
    for qid in ids:
        entity = ents.get(qid)
        kind = kind_of(entity) if entity else None
        if kind is None:
            continue
        out.append((await to_work(entity), kind))
        if len(out) >= limit:
            break
    return out


async def series_members(series_qid: str) -> tuple[str, list[tuple[Game, str]]]:
    """Díly série / franšízy (P179) chronologicky + název série."""

    async def fetch() -> dict[str, Any]:
        query = (
            "SELECT DISTINCT ?item WHERE { ?item wdt:P179 wd:%s . } LIMIT 80" % series_qid
        )
        async with httpx.AsyncClient(timeout=30.0, headers={**_UA, "Accept": "application/sparql-results+json"}) as client:
            r = await client.get(WD_SPARQL, params={"query": query, "format": "json"})
        rows = ((r.json() if r.status_code == 200 else {}).get("results") or {}).get("bindings") or []
        return {"ids": [row["item"]["value"].rsplit("/", 1)[-1] for row in rows if row.get("item")]}

    ids = (await cached_json(f"wd:series:{series_qid}", WEEK, fetch, is_empty=lambda v: not v.get("ids"))).get("ids") or []
    ents = await entities([series_qid, *ids])
    title = _label(ents.get(series_qid) or {})
    works: list[tuple[Game, str]] = []
    for qid in ids:
        entity = ents.get(qid)
        kind = kind_of(entity) if entity else None
        if kind:
            works.append((await to_work(entity), kind))
    works.sort(key=lambda w: w[0].year or 9999)
    return title, works


async def gather_limited(coros, limit: int = 6):
    sem = asyncio.Semaphore(limit)

    async def one(c):
        async with sem:
            return await c

    return await asyncio.gather(*(one(c) for c in coros))
