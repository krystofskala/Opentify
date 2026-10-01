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

import asyncio

import os
from typing import Any

import httpx

from app.catalog.cache import cached_json
from app.catalog.rate_limit import AsyncRateLimiter

DEEZER_BASE_URL = os.environ.get("DEEZER_API_BASE", "https://api.deezer.com")

SEARCH_TTL_SECONDS = 60 * 60
LOOKUP_TTL_SECONDS = 24 * 60 * 60

# Deezer povoluje ~50 req / 5 s -> 0.1 s je přesně na hraně, bez rezervy
# by se občas vrátila kvóta (HTTP 200 s `error`), proto 0.11.
_rate_limiter = AsyncRateLimiter(min_interval_seconds=0.11, key="deezer")


class DeezerUnavailable(RuntimeError):
    pass


class DeezerClient:
    def __init__(self, http_client: httpx.AsyncClient | None = None) -> None:
        self._client = http_client or httpx.AsyncClient(base_url=DEEZER_BASE_URL, timeout=10.0)

    async def _get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any] | None:
        if "own:" in path or any("own:" in str(v) for v in (params or {}).values()):  # vlastní (app/catalog/identity.py)
            return None
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

    async def track(self, track_id: str) -> dict[str, Any] | None:
        """Jedna skladba -- s čerstvým `preview` (30s ukázka; odkaz je
        podepsaný a po čase vyprší, proto se necachuje dlouho)."""

        async def fetch() -> dict[str, Any]:
            result = await self._get(f"/track/{track_id}")
            if result is None:
                raise DeezerUnavailable(track_id)
            return result

        try:
            return await cached_json(f"dz:track:{track_id}", 10 * 60, fetch)
        except (DeezerUnavailable, httpx.HTTPError):
            return None

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

    async def search_artist(self, name: str, limit: int = 5, *, trust_name: bool = True) -> list[dict[str, Any]]:
        """`trust_name=False`: interpret známý jen z vlastních souborů se
        podle jména nepáruje (viz app/catalog/identity.py) -- prázdný výsledek.
        Vyhledávání v appce jde přes `search_typed`, tohle ho neomezuje."""
        if not trust_name:
            from app.catalog.identity import local_only_artist

            if await asyncio.to_thread(local_only_artist, name) is not None:
                return []
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

    async def _cached_data(self, cache_key: str, ttl: int, path: str, params: dict[str, Any]) -> list[dict[str, Any]] | None:
        """`data` pole z Deezer seznamové odpovědi; `None` = zdroj selhal
        (odlišené od prázdného výsledku, ať volající může spadnout na zálohu)."""

        async def fetch() -> dict[str, Any]:
            result = await self._get(path, params)
            if result is None:
                # Výpadek/kvóta (Deezer vrací chybu jako HTTP 200 `{"error"}`)
                # -- vyhodit, ať se NEuloží do cache jako "nic" na celé TTL.
                raise DeezerUnavailable(path)
            return result

        try:
            data = await cached_json(cache_key, ttl, fetch)
        except (DeezerUnavailable, httpx.HTTPError):
            return None
        return data.get("data") or []

    async def search_typed(self, kind: str, query: str, limit: int, offset: int = 0) -> list[dict[str, Any]] | None:
        """`kind` = track|artist|album -- katalogové hledání (rychlé a s
        velkorysým limitem, na rozdíl od MusicBrainz 1 req/s)."""
        return await self._cached_data(
            f"dz:search:{kind}:{query}:{limit}:{offset}",
            SEARCH_TTL_SECONDS,
            f"/search/{kind}",
            {"q": query, "limit": limit, "index": offset},
        )

    async def find_track(self, artist: str, title: str) -> dict[str, Any] | None:
        """Přesnější párování "interpret + název" (Apple žebříčky, budoucí
        generované playlisty) přes Deezer advanced search syntaxi."""
        query = f'artist:"{artist}" track:"{title}"'
        tracks = await self._cached_data(f"dz:find_track:{query}", LOOKUP_TTL_SECONDS, "/search/track", {"q": query, "limit": 3})
        if not tracks:
            tracks = await self._cached_data(
                f"dz:find_track_loose:{artist} {title}", LOOKUP_TTL_SECONDS, "/search/track", {"q": f"{artist} {title}", "limit": 3}
            )
        return tracks[0] if tracks else None

    async def playlist_tracks(self, playlist_id: str, limit: int = 100) -> list[dict[str, Any]] | None:
        return await self._cached_data(
            f"dz:playlist_tracks:{playlist_id}:{limit}", 60 * 60, f"/playlist/{playlist_id}/tracks", {"limit": limit}
        )

    async def playlist(self, playlist_id: str) -> dict[str, Any] | None:
        async def fetch() -> dict[str, Any]:
            result = await self._get(f"/playlist/{playlist_id}", {"limit": 1})
            if result is None:
                raise DeezerUnavailable(playlist_id)
            return result

        try:
            return await cached_json(f"dz:playlist:{playlist_id}", 60 * 60, fetch)
        except (DeezerUnavailable, httpx.HTTPError):
            return None

    async def artist(self, artist_id: str) -> dict[str, Any] | None:
        """Jeden interpret podle Deezer id (fotka přesně jeho, ne podle jména)."""

        async def fetch() -> dict[str, Any]:
            result = await self._get(f"/artist/{artist_id}")
            if result is None or result.get("error"):
                raise DeezerUnavailable(artist_id)
            return result

        try:
            return await cached_json(f"dz:artist:{artist_id}", LOOKUP_TTL_SECONDS, fetch)
        except (DeezerUnavailable, httpx.HTTPError):
            return None

    async def album(self, album_id: str) -> dict[str, Any] | None:
        """Jedno album (kvůli obalu `cover_xl`), když Deezer id už známe."""

        async def fetch() -> dict[str, Any]:
            result = await self._get(f"/album/{album_id}")
            if result is None or result.get("error"):
                raise DeezerUnavailable(album_id)
            return result

        try:
            return await cached_json(f"dz:album:{album_id}", LOOKUP_TTL_SECONDS, fetch)
        except (DeezerUnavailable, httpx.HTTPError):
            return None

    async def chart_tracks(self, genre_id: int, limit: int = 50) -> list[dict[str, Any]] | None:
        return await self._cached_data(f"dz:chart:{genre_id}:tracks:{limit}", 60 * 60, f"/chart/{genre_id}/tracks", {"limit": limit})

    async def chart_playlists(self, limit: int = 20) -> list[dict[str, Any]] | None:
        return await self._cached_data(f"dz:chart:0:playlists:{limit}", 60 * 60, "/chart/0/playlists", {"limit": limit})

    async def album_tracks(self, album_id: str) -> list[dict[str, Any]] | None:
        return await self._cached_data(f"dz:album_tracks:{album_id}", LOOKUP_TTL_SECONDS, f"/album/{album_id}/tracks", {"limit": 200})

    async def artist_albums(self, artist_id: str) -> list[dict[str, Any]] | None:
        return await self._cached_data(f"dz:artist_albums:{artist_id}", LOOKUP_TTL_SECONDS, f"/artist/{artist_id}/albums", {"limit": 100})

    async def artist_radio(self, artist_id: str) -> list[dict[str, Any]] | None:
        """~25 skladeb "v podobném duchu" -- základ nových skladeb v osobních mixech."""
        return await self._cached_data(f"dz:artist_radio:{artist_id}", 12 * 60 * 60, f"/artist/{artist_id}/radio", {"limit": 50})

    async def artist_related(self, artist_id: str, limit: int = 20) -> list[dict[str, Any]] | None:
        return await self._cached_data(
            f"dz:artist_related:{artist_id}:{limit}", LOOKUP_TTL_SECONDS, f"/artist/{artist_id}/related", {"limit": limit}
        )

    async def artist_top(self, artist_id: str, limit: int = 5) -> list[dict[str, Any]] | None:
        return await self._cached_data(
            f"dz:artist_top:{artist_id}:{limit}", LOOKUP_TTL_SECONDS, f"/artist/{artist_id}/top", {"limit": limit}
        )

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
