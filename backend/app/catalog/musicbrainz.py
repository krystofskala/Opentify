"""Tenký async adaptér nad MusicBrainz WS/2 (https://musicbrainz.org/doc/MusicBrainz_API).

Drží se dvou pravidel z MB TOS pro anonymní přístup: max. 1 request/s (jinak
dočasný ban IP) a povinný identifikující `User-Agent`. Obojí je tady, ne v
service vrstvě, aby na to žádný volající nemohl zapomenout.

Odpovědi se cachují v Redis (`app.catalog.cache`) — TTL je zvolen podle toho,
jak často se dané entity typicky mění (search výsledky krátce, diskografie
a detail interpreta/alba dlouho, protože MusicBrainz metadata jsou takřka
statická).
"""

from __future__ import annotations

import asyncio
import os
from typing import Any

import httpx

from app.catalog.cache import cached_json
from app.catalog.rate_limit import AsyncRateLimiter, RateLimitBusy

MB_BASE_URL = os.environ.get("MUSICBRAINZ_BASE_URL", "https://musicbrainz.org/ws/2")
MB_USER_AGENT = os.environ.get(
    "MUSICBRAINZ_USER_AGENT", "VaultPersonalMusicSystem/0.1.0 ( set-a-contact-in-env )"
)

SEARCH_TTL_SECONDS = 60 * 60          # 1h — vyhledávání se může časem doplňovat
LOOKUP_TTL_SECONDS = 24 * 60 * 60     # 24h — detail/diskografie jsou téměř statické

# Anonymní přístup: max 1 request/s, jinak MB dočasně banuje IP (503).
# `max_waiters`: víc čekajících = odpověď za >6 s, to už uživatel nepočká a
# jen by držel DB spojení -- selže hned (-> 503 "zkus znovu"), viz RateLimitBusy.
_rate_limiter = AsyncRateLimiter(min_interval_seconds=1.0, max_waiters=6)


class MusicBrainzError(RuntimeError):
    pass


class MusicBrainzClient:
    def __init__(self, http_client: httpx.AsyncClient | None = None) -> None:
        self._client = http_client or httpx.AsyncClient(
            base_url=MB_BASE_URL,
            headers={"User-Agent": MB_USER_AGENT, "Accept": "application/json"},
            timeout=10.0,
        )

    async def _get(self, path: str, params: dict[str, Any]) -> dict[str, Any]:
        # Pár opakování s krátkým odstupem na dočasné 503/výpadky -- bez
        # tohohle jeden zaškobrtnutý request uprostřed dlouhého skenu knihovny
        # (tisíce sekvenčních MB volání kvůli 1 req/s limitu, viz níž) tiše
        # spadl na `MusicBrainzError`, kterou volající (`CatalogService.
        # match_release_by_tracklist` apod.) bere jako "match se nenašel" --
        # jedna náhodná 503 uprostřed skenu tak dokázala rozbít album-level
        # match na per-track fallback pro celou složku (živě ověřeno).
        last_exc: MusicBrainzError | None = None
        for attempt in range(3):
            if attempt > 0:
                await asyncio.sleep(1.0 * attempt)
            try:
                await _rate_limiter.wait()
            except RateLimitBusy as exc:
                raise MusicBrainzError("MusicBrainz fronta je plná -- zkus to za chvíli znovu") from exc
            try:
                resp = await self._client.get(path, params={**params, "fmt": "json"})
            except httpx.TransportError as exc:
                last_exc = MusicBrainzError(f"MusicBrainz nedostupný: {exc}")
                continue
            if resp.status_code == 503:
                last_exc = MusicBrainzError("MusicBrainz rate-limit (503) — zkus to za chvíli znovu")
                continue
            break
        else:
            raise last_exc  # type: ignore[misc]  -- smyčka proběhla 3x, `last_exc` je vždy nastavené
        resp.raise_for_status()
        return resp.json()

    async def search(
        self, entity: str, query: str, limit: int, offset: int
    ) -> dict[str, Any]:
        """`entity` je nativní MB endpoint: artist | release-group | recording."""
        cache_key = f"mb:search:{entity}:{query}:{limit}:{offset}"

        async def fetch() -> dict[str, Any]:
            return await self._get(f"/{entity}", {"query": query, "limit": limit, "offset": offset})

        return await cached_json(cache_key, SEARCH_TTL_SECONDS, fetch)

    async def get_artist(self, mbid: str) -> dict[str, Any]:
        # `url-rels` nese odkaz na Wikidata (`get_artist_bio` v service.py z
        # něj dohledá životopis), `artist-rels` vztahy k dalším interpretům
        # (člen kapely, spolupráce...) pro "Podobní interpreti". Oboje na
        # stejném requestu jako `country` (`_enrich_artist_country`) -- žádný
        # extra dotaz navíc.
        cache_key = f"mb:artist:{mbid}"

        async def fetch() -> dict[str, Any]:
            return await self._get(f"/artist/{mbid}", {"inc": "aliases+url-rels+artist-rels"})

        return await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)

    async def browse_release_groups(
        self, artist_mbid: str, release_type: str | None, limit: int, offset: int
    ) -> dict[str, Any]:
        cache_key = f"mb:release-groups:{artist_mbid}:{release_type}:{limit}:{offset}"
        params: dict[str, Any] = {"artist": artist_mbid, "limit": limit, "offset": offset, "inc": "genres"}
        if release_type:
            params["type"] = release_type

        async def fetch() -> dict[str, Any]:
            return await self._get("/release-group", params)

        return await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)

    async def get_release_group(self, rgid: str) -> dict[str, Any]:
        cache_key = f"mb:release-group:{rgid}"

        async def fetch() -> dict[str, Any]:
            return await self._get(f"/release-group/{rgid}", {"inc": "artist-credits+genres"})

        return await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)

    async def get_release_group_tracks(self, rgid: str) -> dict[str, Any]:
        """Tracklist žije na konkrétní `release`, ne na `release-group` (ta je jen
        abstraktní seskupení edic napříč zeměmi/médii). Vezmeme první 'official'
        release dané release-group a jeho media/tracks použijeme jako
        reprezentativní tracklist — pro osobní katalog stačí jedna kanonická
        verze, ne řešit rozdíly mezi edicemi."""
        cache_key = f"mb:release-group-tracks:{rgid}"

        async def fetch() -> dict[str, Any]:
            return await self._get(
                "/release",
                {
                    "release-group": rgid,
                    "inc": "recordings+artist-credits+isrcs",
                    "status": "official",
                },
            )

        return await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)

    async def aclose(self) -> None:
        await self._client.aclose()


_client: MusicBrainzClient | None = None


def get_musicbrainz_client() -> MusicBrainzClient:
    global _client
    if _client is None:
        _client = MusicBrainzClient()
    return _client


async def close_musicbrainz_client() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
