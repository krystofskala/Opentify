"""Tenký async adaptér nad veřejným Deezer API (https://developers.deezer.com/api).

Deezer tady slouží jen jako *doplněk* k MusicBrainz — cover art ve vyšší
kvalitě a krátké 30s náhledy (`preview`), ne jako zdroj struktury katalogu
(ta je vždy z MusicBrainz). Nejpřesnější spojení MB nahrávky s Deezer
skladbou je přes ISRC (`/track/isrc:{isrc}`), pokud ho MB pro danou
nahrávku zná — jmenný matching je nespolehlivý a záměrně mimo scope.

Deezer nedokumentuje striktní rate limit stejně explicitně jako MusicBrainz;
v praxi tolerují řádově desítky requestů za sekundu. Přesto omezujeme na
slušnou kadenci, hlavně aby jeden `discography` request s desítkami skladeb
nezpůsobil frontu paralelních volání.
"""

from __future__ import annotations

import os
from typing import Any

import httpx

from app.catalog.cache import cached_json
from app.catalog.rate_limit import AsyncRateLimiter

DEEZER_BASE_URL = os.environ.get("DEEZER_API_BASE", "https://api.deezer.com")

SEARCH_TTL_SECONDS = 60 * 60
LOOKUP_TTL_SECONDS = 24 * 60 * 60

_rate_limiter = AsyncRateLimiter(min_interval_seconds=0.15)


class DeezerClient:
    def __init__(self, http_client: httpx.AsyncClient | None = None) -> None:
        self._client = http_client or httpx.AsyncClient(base_url=DEEZER_BASE_URL, timeout=10.0)

    async def _get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any] | None:
        await _rate_limiter.wait()
        try:
            resp = await self._client.get(path, params=params or {})
        except httpx.TransportError:
            return None
        if resp.status_code == 404:
            return None
        resp.raise_for_status()
        data = resp.json()
        if isinstance(data, dict) and data.get("error"):
            # Deezer vrací chyby s HTTP 200 a `{"error": {...}}` payloadem.
            return None
        return data

    async def find_track_by_isrc(self, isrc: str) -> dict[str, Any] | None:
        cache_key = f"dz:isrc:{isrc}"

        async def fetch() -> dict[str, Any] | None:
            return await self._get(f"/track/isrc:{isrc}")

        return await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)

    async def search(self, query: str, limit: int) -> dict[str, Any] | None:
        cache_key = f"dz:search:{query}:{limit}"

        async def fetch() -> dict[str, Any] | None:
            return await self._get("/search", {"q": query, "limit": limit})

        return await cached_json(cache_key, SEARCH_TTL_SECONDS, fetch)

    async def search_artist(self, name: str, limit: int = 5) -> list[dict[str, Any]]:
        cache_key = f"dz:search_artist:{name}:{limit}"

        async def fetch() -> dict[str, Any] | None:
            return await self._get("/search/artist", {"q": name, "limit": limit})

        data = await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)
        return (data or {}).get("data") or []

    async def search_album(self, artist: str, title: str, limit: int = 5) -> list[dict[str, Any]]:
        query = f'artist:"{artist}" album:"{title}"'
        cache_key = f"dz:search_album:{query}:{limit}"

        async def fetch() -> dict[str, Any] | None:
            return await self._get("/search/album", {"q": query, "limit": limit})

        data = await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)
        return (data or {}).get("data") or []

    async def aclose(self) -> None:
        await self._client.aclose()


_client: DeezerClient | None = None


def get_deezer_client() -> DeezerClient:
    global _client
    if _client is None:
        _client = DeezerClient()
    return _client


async def close_deezer_client() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
