"""Čistý název a autor knihy z katalogu audioknihy.cz.

Název vydání na trackeru bývá "Jirotka Zdeněk - Saturnin (2003)(čte ...)"
a tagy souborů často nic (nebo "Track 01"). Katalog audioknihy.cz (~12 tisíc
českých audioknih) má veřejné vyhledávání (`/api/search`) s názvem, autorem
a obalem. Přebírá se jen jistá shoda: všechna slova názvu z katalogu
i příjmení autora jsou v názvu vydání -- jinak zůstává, co je.
"""

from __future__ import annotations

import logging
import re
import unicodedata

import httpx

from app.spoken import sktorrent
from app.spoken.importer import guess_from_release

logger = logging.getLogger(__name__)

SEARCH_URL = "https://audioknihy.cz/api/search"
_UA = "Mozilla/5.0 (Opentify)"


def _words(text: str) -> list[str]:
    plain = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().lower()
    return re.findall(r"[a-z0-9]+", plain)


def best_match(release_title: str, items: list[dict]) -> dict | None:
    """Nejdelší název z katalogu, jehož slova i příjmení některého autora
    jsou v názvu vydání ("Saturnin se vrací" má přednost před "Saturnin")."""
    have = set(_words(release_title))
    best, best_len = None, 0
    for item in items:
        if item.get("type") != "work" or not item.get("title") or not item.get("author_name"):
            continue
        title = _words(item["title"])
        if not title or not set(title) <= have:
            continue
        surnames = [w[-1] for a in str(item["author_name"]).split(",") if (w := _words(a))]
        if not any(s in have for s in surnames):
            continue
        if len(title) > best_len:
            best, best_len = item, len(title)
    return best


async def lookup(release_title: str) -> dict | None:
    """{title, author, coverUrl} pro vydání, nebo None (nic jistého)."""
    query = guess_from_release(release_title)["title"]
    # Přes VPN jako všechno kolem audioknih (sktorrent._proxy je fail-closed).
    async with httpx.AsyncClient(proxy=sktorrent._proxy(), timeout=15, headers={"User-Agent": _UA}) as c:
        resp = await c.get(SEARCH_URL, params={"q": query[:200]})
        resp.raise_for_status()
        data = resp.json()
    items = [i for g in data.get("groups") or [] if g.get("type") == "work" for i in g.get("items") or []]
    hit = best_match(release_title, items)
    if hit is None:
        return None
    return {"title": hit["title"], "author": hit["author_name"], "coverUrl": hit.get("cover_url")}
