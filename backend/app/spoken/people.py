"""Autoři a interpreti mluveného slova: fotka a medailonek z Wikidat /
Wikipedie, stejně jako u interpretů hudby (`app/catalog/wikimedia.py`).

Mluvené slovo nemá MBID, takže se člověk hledá podle jména -- přísně:
stejné jméno (bez diakritiky, i "Příjmení, Jméno"), člověk (P31 = Q5)
a povolání, které k roli sedí. Jmenovec (fotbalista Karel Čapek) se tak
nepřiřadí; radši nic než cizí fotka.
"""

from __future__ import annotations

import asyncio
import logging
import time
import unicodedata
from typing import Any

import httpx

from app.catalog.cache import cached_json
from app.catalog.wikimedia import WIKIMEDIA_USER_AGENT, get_wikimedia_client

logger = logging.getLogger(__name__)

_http = httpx.AsyncClient(timeout=10.0, headers={"User-Agent": WIKIMEDIA_USER_AGENT})
WIKIDATA = "https://www.wikidata.org/w/api.php"
TTL_S = 30 * 24 * 3600
# Wikidata omezuje počet dotazů (429 při rychlém sledu, ověřeno 7. 10.) --
# po jednom a s odstupem.
_GAP_S = 0.6
_lock = asyncio.Lock()
_last = 0.0


async def _wd(params: dict[str, Any]) -> dict[str, Any]:
    global _last
    async with _lock:
        wait = _GAP_S - (time.monotonic() - _last)
        if wait > 0:
            await asyncio.sleep(wait)
        try:
            resp = await _http.get(WIKIDATA, params={**params, "format": "json"})
            if resp.status_code == 429:
                # Jednou znovu po pauze, kterou si Wikidata řeknou (nejvýš 10 s).
                try:
                    pause = min(float(resp.headers.get("retry-after") or 5), 10.0)
                except ValueError:
                    pause = 5.0
                await asyncio.sleep(pause)
                resp = await _http.get(WIKIDATA, params={**params, "format": "json"})
        finally:
            _last = time.monotonic()
    resp.raise_for_status()  # 429 -> chyba, výsledek se neuloží
    data = resp.json()
    if isinstance(data, dict) and data.get("error"):
        # Chyba API v odpovědi 200 (maxlag, špatný dotaz) -- dřív se uložila
        # jako "kniha bez řady" na 30 dní (audit 8. 10.).
        raise RuntimeError(f"wikidata: {data['error'].get('code') if isinstance(data['error'], dict) else data['error']}")
    return data

# Povolání (P106). Autor: spisovatel, romanopisec, básník, autor, dramatik,
# scenárista, novinář, překladatel, autor dětské literatury, esejista,
# historik, filozof, humorista. Interpret: herec (i dabing, divadlo, film,
# TV), moderátor -- a autor, který čte sám sebe.
WRITERS = {
    "Q36180", "Q6625963", "Q49757", "Q482980", "Q214917", "Q28389", "Q1930187", "Q333634",
    "Q4853732", "Q11774202", "Q201788", "Q4964182", "Q18844224", "Q15949613",
}
ACTORS = {"Q33999", "Q2405480", "Q2259451", "Q10800557", "Q10798782", "Q13590141", "Q947873", "Q2722764"}


def fold(text: str | None) -> str:
    from app.spoken.catalog import _SPECIAL  # "Nesbø" -> "nesbo", polské ł

    text = unicodedata.normalize("NFKD", (text or "").translate(_SPECIAL)).encode("ascii", "ignore").decode().casefold()
    return " ".join(text.replace(",", " , ").split()).replace(" , ", ", ")


def name_variants(name: str) -> set[str]:
    """"Jirotka, Zdeněk" i "Zdeněk Jirotka"."""
    out = {fold(name)}
    if "," in name:
        last, _, first = name.partition(",")
        out.add(fold(f"{first} {last}"))
    return out


def _claims_ids(entity: dict[str, Any], prop: str) -> set[str]:
    out = set()
    for c in (entity.get("claims") or {}).get(prop) or []:
        value = ((c.get("mainsnak") or {}).get("datavalue") or {}).get("value")
        if isinstance(value, dict) and value.get("id"):
            out.add(value["id"])
    return out


def pick(entities: list[dict[str, Any]], name: str, role: str) -> dict[str, Any] | None:
    """Člověk se stejným jménem a povoláním k roli (v pořadí hledání)."""
    wanted = name_variants(name)
    jobs = WRITERS if role == "author" else ACTORS | WRITERS
    for e in entities:
        labels = {fold((v or {}).get("value")) for v in (e.get("labels") or {}).values()}
        aliases = {fold(a.get("value")) for vs in (e.get("aliases") or {}).values() for a in vs or []}
        if not (wanted & (labels | aliases)):
            continue
        if "Q5" not in _claims_ids(e, "P31"):
            continue
        if _claims_ids(e, "P106") & jobs:
            return e
    return None


async def _image(entity: dict[str, Any]) -> str | None:
    try:
        filename = entity["claims"]["P18"][0]["mainsnak"]["datavalue"]["value"]
    except (KeyError, IndexError, TypeError):
        return None
    try:
        # `Special:FilePath` přesměruje na upload.wikimedia.org (s CORS).
        img = await _http.head(
            f"https://commons.wikimedia.org/wiki/Special:FilePath/{filename}",
            params={"width": 800},
            follow_redirects=True,
        )
    except httpx.HTTPError:
        return None
    return str(img.url) if img.status_code == 200 else None


async def _lookup(name: str, role: str) -> dict[str, Any]:
    first_last = sorted(name_variants(name), key=lambda v: "," in v)[0]
    found = await _wd({"action": "wbsearchentities", "search": first_last, "language": "cs", "uselang": "cs",
                       "type": "item", "limit": 7})
    ids = [r["id"] for r in (found.get("search") or []) if r.get("id")]
    if not ids:
        return {}
    data = await _wd({"action": "wbgetentities", "ids": "|".join(ids), "props": "claims|labels|aliases|descriptions|sitelinks",
                      "languages": "cs|en", "sitefilter": "cswiki|enwiki"})
    entities = data.get("entities") or {}
    entity = pick([entities[i] for i in ids if i in entities], name, role)
    if entity is None:
        return {}
    qid = entity["id"]
    descriptions = entity.get("descriptions") or {}
    return {
        "qid": qid,
        "image": await _image(entity),
        "bio": await get_wikimedia_client().get_bio_from_sitelinks(entity.get("sitelinks") or {}),
        "description": ((descriptions.get("cs") or descriptions.get("en")) or {}).get("value"),
    }


async def wiki_person(name: str, role: str = "author") -> dict[str, Any]:
    """{qid, image, bio, description} nebo {} (nenalezen / Wikidata
    nedostupná). Mezipaměť 30 dní i pro "nenalezen"."""
    role = "narrator" if role == "narrator" else "author"
    key = f"spoken:person:wiki:v1:{role}:{fold(name)}"

    async def build() -> dict[str, Any]:
        try:
            return {"found": await _lookup(name, role)}
        except (httpx.HTTPError, ValueError) as exc:
            logger.info("wikidata %s: %s", name, exc)
            raise  # chyba sítě se neukládá -- příště znovu

    try:
        return (await cached_json(key, TTL_S, build)).get("found") or {}
    except (httpx.HTTPError, ValueError):
        return {}
