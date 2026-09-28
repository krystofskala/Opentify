"""Text skladeb přes veřejné LRCLIB API (https://lrclib.net/docs) — stejný
vzor jako `app/catalog/deezer.py`: tenký httpx adaptér + cache přes
`app.catalog.cache.cached_json`, aby opakovaný dotaz na tutéž skladbu
(mini bar i Now Playing screen ji můžou chtít znovu ve stejné relaci) nešel
pokaždé ven.

Používáme `/api/search`, ne přesný `/api/get` (ten vyžaduje bitově přesnou
délku skladby) — lokální soubory mají délku v tazích často mírně jinou než
LRCLIB záznam (jiný encoder/tagger), takže striktní shoda by zbytečně
propadala. `/search` vrátí kandidáty seřazené podle relevance, z nich
vezmeme první se synchronizovaným textem, jinak první s prostým textem.
"""

from __future__ import annotations

import os
from typing import Any

import httpx

from app.catalog.cache import cached_json

LRCLIB_BASE_URL = os.environ.get("LRCLIB_API_BASE", "https://lrclib.net/api")
LYRICS_TTL_SECONDS = 7 * 24 * 60 * 60  # text skladby se nemění, týden je bezpečný

_NOT_FOUND = {"not_found": True}

_client = httpx.AsyncClient(base_url=LRCLIB_BASE_URL, timeout=10.0)


async def fetch_lyrics(
    *,
    track_name: str,
    artist_name: str | None,
    album_name: str | None,
) -> dict[str, Any] | None:
    cache_key = f"lyrics:{artist_name or ''}:{track_name}"

    async def fetch() -> dict[str, Any]:
        params: dict[str, Any] = {"track_name": track_name}
        if artist_name:
            params["artist_name"] = artist_name
        if album_name:
            params["album_name"] = album_name
        try:
            resp = await _client.get("/search", params=params)
            resp.raise_for_status()
            results = resp.json()
        except (httpx.TransportError, httpx.HTTPStatusError, ValueError):
            return _NOT_FOUND
        if not isinstance(results, list) or not results:
            return _NOT_FOUND

        best = next((r for r in results if r.get("syncedLyrics")), None) or next(
            (r for r in results if r.get("plainLyrics")), None
        )
        if best is None:
            return _NOT_FOUND
        return {
            "plain": best.get("plainLyrics"),
            "synced": best.get("syncedLyrics"),
            "instrumental": bool(best.get("instrumental")),
        }

    result = await cached_json(cache_key, LYRICS_TTL_SECONDS, fetch)
    if result is None or result.get("not_found"):
        return None
    return result
