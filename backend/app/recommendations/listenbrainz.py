"""Tenký async adaptér nad ListenBrainz API (https://listenbrainz.org/api/1/).

`LISTENBRAINZ_BASE_URL` (viz docker-compose.yml) typicky míří na vlastní
self-hostnutou instanci, ne na listenbrainz.org — ARCHITECTURE.md ji staví
jako volitelnou komponentu vlastního stacku, ne cizí SaaS.

Cílem jsou dva konkrétní "troi patch" výstupy, které ListenBrainz uživatelům
pravidelně generuje jako JSPF playlisty:

  - `daily-jams`         -> personalizovaný denní mix
  - `weekly-exploration` -> týdenní tipy na objevování nové hudby

Playlisty se dohledávají přes `/1/user/{user}/playlists/createdfor` podle
`source_patch` v JSPF extension metadatech (ne podle `title` stringu, který
je datovaný/lokalizovaný a pro matching nespolehlivý).
"""

from __future__ import annotations

import os
from typing import Any

import httpx

from app.catalog.cache import cached_json
from app.catalog.rate_limit import AsyncRateLimiter

LISTENBRAINZ_BASE_URL = os.environ.get("LISTENBRAINZ_BASE_URL", "http://listenbrainz:8080")

# createdfor index se přegenerovává cca denně/týdně podle patchu -> hodinová
# cache stačí na to, aby opakované otevření appky nebušilo na server pokaždé.
PLAYLISTS_INDEX_TTL_SECONDS = 60 * 60
PLAYLIST_DETAIL_TTL_SECONDS = 30 * 60

_rate_limiter = AsyncRateLimiter(min_interval_seconds=0.2)


class ListenBrainzError(RuntimeError):
    pass


class ListenBrainzClient:
    def __init__(self, http_client: httpx.AsyncClient | None = None) -> None:
        self._client = http_client or httpx.AsyncClient(
            base_url=LISTENBRAINZ_BASE_URL, timeout=10.0
        )

    async def _get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        await _rate_limiter.wait()
        try:
            resp = await self._client.get(path, params=params or {})
        except httpx.TransportError as exc:
            raise ListenBrainzError(f"ListenBrainz instance nedostupná: {exc}") from exc
        if resp.status_code == 404:
            raise ListenBrainzError(f"ListenBrainz 404 na {path}")
        resp.raise_for_status()
        # LB vrací 204 (prázdné tělo) pro účty/entity bez dostatečných dat na
        # spočtení statistiky -- to je legitimní "zatím nic", ne chyba, ale
        # `.json()` na prázdném těle by spadlo na JSONDecodeError.
        if resp.status_code == 204 or not resp.content:
            return {}
        return resp.json()

    async def list_created_for_playlists(self, user_name: str) -> list[dict[str, Any]]:
        cache_key = f"lb:createdfor:{user_name}"

        async def fetch() -> list[dict[str, Any]]:
            data = await self._get(f"/1/user/{user_name}/playlists/createdfor")
            return data.get("playlists", [])

        return await cached_json(cache_key, PLAYLISTS_INDEX_TTL_SECONDS, fetch)

    async def get_playlist(self, playlist_mbid: str) -> dict[str, Any]:
        cache_key = f"lb:playlist:{playlist_mbid}"

        async def fetch() -> dict[str, Any]:
            return await self._get(f"/1/playlist/{playlist_mbid}")

        return await cached_json(cache_key, PLAYLIST_DETAIL_TTL_SECONDS, fetch)

    async def find_playlist_mbid_by_patch(self, user_name: str, source_patch: str) -> str | None:
        """`source_patch` je např. "daily-jams" nebo "weekly-exploration" —
        hodnota, kterou troi patch zapisuje do JSPF extension metadat."""
        for entry in await self.list_created_for_playlists(user_name):
            playlist = entry.get("playlist", {})
            metadata = (
                playlist.get("extension", {})
                .get("https://musicbrainz.org/doc/jspf#playlist", {})
                .get("additional_metadata", {})
                .get("algorithm_metadata", {})
            )
            if metadata.get("source_patch") == source_patch:
                identifier = playlist.get("identifier", "")
                mbid = identifier.rstrip("/").rsplit("/", 1)[-1]
                return mbid or None
        return None

    async def aclose(self) -> None:
        await self._client.aclose()


_client: ListenBrainzClient | None = None


def get_listenbrainz_client() -> ListenBrainzClient:
    global _client
    if _client is None:
        _client = ListenBrainzClient()
    return _client


async def close_listenbrainz_client() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None


# ---------------------------------------------------------------------
# Veřejné listenbrainz.org — sitewide statistiky a similar-users existují
# smysluplně jen na skutečné komunitní instanci (LB je počítá batch Spark
# jobem nad celým datasetem), self-hosted `LISTENBRAINZ_BASE_URL` výše je
# typicky jednouživatelská instance bez týhle pipeline. Proto samostatný
# klient s napevno danou URL veřejného API, ne env-přepsatelný jako výše.
# ---------------------------------------------------------------------

LISTENBRAINZ_PUBLIC_API_BASE_URL = "https://api.listenbrainz.org"

SITEWIDE_STATS_TTL_SECONDS = 60 * 60
SIMILAR_USERS_TTL_SECONDS = 60 * 60 * 6
USER_STATS_TTL_SECONDS = 60 * 60

_public_rate_limiter = AsyncRateLimiter(min_interval_seconds=0.2)


class ListenBrainzPublicClient:
    def __init__(self, http_client: httpx.AsyncClient | None = None) -> None:
        self._client = http_client or httpx.AsyncClient(
            base_url=LISTENBRAINZ_PUBLIC_API_BASE_URL, timeout=10.0
        )

    async def _get(self, path: str, params: dict[str, Any] | None = None) -> dict[str, Any]:
        await _public_rate_limiter.wait()
        try:
            resp = await self._client.get(path, params=params or {})
        except httpx.TransportError as exc:
            raise ListenBrainzError(f"listenbrainz.org nedostupný: {exc}") from exc
        if resp.status_code == 404:
            raise ListenBrainzError(f"listenbrainz.org 404 na {path}")
        resp.raise_for_status()
        # 204 = LB nemá pro tenhle účet/rozsah spočtenou statistiku (nová
        # nebo neaktivní konta) -- legitimní prázdný stav, ne chyba.
        if resp.status_code == 204 or not resp.content:
            return {}
        return resp.json()

    async def sitewide_top_recordings(self, range_: str, count: int) -> list[dict[str, Any]]:
        cache_key = f"lb-public:sitewide-recordings:{range_}:{count}"

        async def fetch() -> list[dict[str, Any]]:
            data = await self._get("/1/stats/sitewide/recordings", {"range": range_, "count": count})
            return data.get("payload", {}).get("recordings", [])

        return await cached_json(cache_key, SITEWIDE_STATS_TTL_SECONDS, fetch)

    async def similar_users(self, user_name: str, count: int) -> list[dict[str, Any]]:
        cache_key = f"lb-public:similar-users:{user_name}"

        async def fetch() -> list[dict[str, Any]]:
            data = await self._get(f"/1/user/{user_name}/similar-users")
            return data.get("payload", [])

        users = await cached_json(cache_key, SIMILAR_USERS_TTL_SECONDS, fetch)
        return users[:count]

    async def user_top_recordings(self, user_name: str, range_: str, count: int) -> list[dict[str, Any]]:
        cache_key = f"lb-public:user-recordings:{user_name}:{range_}:{count}"

        async def fetch() -> list[dict[str, Any]]:
            data = await self._get(f"/1/stats/user/{user_name}/recordings", {"range": range_, "count": count})
            return data.get("payload", {}).get("recordings", [])

        return await cached_json(cache_key, USER_STATS_TTL_SECONDS, fetch)

    async def aclose(self) -> None:
        await self._client.aclose()


_public_client: ListenBrainzPublicClient | None = None


def get_listenbrainz_public_client() -> ListenBrainzPublicClient:
    global _public_client
    if _public_client is None:
        _public_client = ListenBrainzPublicClient()
    return _public_client


async def close_listenbrainz_public_client() -> None:
    global _public_client
    if _public_client is not None:
        await _public_client.aclose()
        _public_client = None
