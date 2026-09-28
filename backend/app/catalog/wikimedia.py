"""Tenký async adaptér nad veřejným Wikidata/Wikipedia API -- zdroj životopisu
interpreta pro `CatalogService.get_artist_bio` (viz `routes/catalog.py`).

Obě API jsou bez klíče, žádný přísný rate limit jako MusicBrainz -- přesto
cachujeme přes `cached_json`, ať se stejný interpret znovu netahá při každém
otevření obrazovky. Řetězec je: MusicBrainz `url-rels` (Wikidata odkaz) ->
Wikidata entita (sitelinks) -> Wikipedia REST summary (krátký extrakt).
Kterýkoliv krok může chybět (interpret nemá Wikidata odkaz, Wikidata nemá
článek v cs/en, ...) -- volající to bere jako "žádný životopis", ne chybu.
"""

from __future__ import annotations

import os
from typing import Any

import httpx

from app.catalog.cache import cached_json

WIKIDATA_API_BASE = os.environ.get("WIKIDATA_API_BASE", "https://www.wikidata.org/w/api.php")

# Wikimedia (Wikidata i Wikipedia) blokuje requesty bez popisného
# `User-Agent` (https://meta.wikimedia.org/wiki/User-Agent_policy) -- bez
# tohohle httpx výchozí UA dostal 403 na *každý* dotaz, živě ověřeno.
WIKIMEDIA_USER_AGENT = os.environ.get(
    "WIKIMEDIA_USER_AGENT", "VaultPersonalMusicSystem/0.1.0 ( set-a-contact-in-env )"
)

LOOKUP_TTL_SECONDS = 24 * 60 * 60  # 24h -- životopisy se prakticky nemění

# Preferované jazykové mutace Wikipedie v pořadí -- appka je česky lokalizovaná,
# ale řada menších interpretů má jen anglický článek.
_PREFERRED_WIKIS = ["cswiki", "enwiki"]
_WIKI_TO_LANG = {"cswiki": "cs", "enwiki": "en"}


class WikimediaClient:
    def __init__(self, http_client: httpx.AsyncClient | None = None) -> None:
        self._client = http_client or httpx.AsyncClient(
            headers={"User-Agent": WIKIMEDIA_USER_AGENT}, timeout=10.0
        )

    async def _get_wikidata_sitelinks(self, qid: str) -> dict[str, Any]:
        cache_key = f"wikidata:sitelinks:{qid}"

        async def fetch() -> dict[str, Any]:
            resp = await self._client.get(
                WIKIDATA_API_BASE,
                params={
                    "action": "wbgetentities",
                    "ids": qid,
                    "props": "sitelinks",
                    "format": "json",
                },
            )
            resp.raise_for_status()
            return resp.json()

        return await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)

    async def _get_wikipedia_summary(self, lang: str, title: str) -> dict[str, Any] | None:
        cache_key = f"wikipedia:summary:{lang}:{title}"

        async def fetch() -> dict[str, Any] | None:
            resp = await self._client.get(f"https://{lang}.wikipedia.org/api/rest_v1/page/summary/{title}")
            if resp.status_code == 404:
                return None
            resp.raise_for_status()
            return resp.json()

        return await cached_json(cache_key, LOOKUP_TTL_SECONDS, fetch)

    async def get_bio_from_wikidata(self, wikidata_qid: str) -> str | None:
        """`wikidata_qid` je jen `Q...` část URL (viz
        `CatalogService._extract_wikidata_qid`). Zkusí čeština -> angličtina,
        vrátí první nalezený extrakt, jinak `None` -- nikdy nevyhodí."""
        try:
            entity_data = await self._get_wikidata_sitelinks(wikidata_qid)
        except httpx.HTTPError:
            return None

        entity = (entity_data.get("entities") or {}).get(wikidata_qid)
        if not entity:
            return None
        sitelinks = entity.get("sitelinks") or {}

        for wiki_key in _PREFERRED_WIKIS:
            sitelink = sitelinks.get(wiki_key)
            if not sitelink or not sitelink.get("title"):
                continue
            lang = _WIKI_TO_LANG[wiki_key]
            try:
                summary = await self._get_wikipedia_summary(lang, sitelink["title"])
            except httpx.HTTPError:
                continue
            if summary and summary.get("extract"):
                return summary["extract"]
        return None

    async def aclose(self) -> None:
        await self._client.aclose()


_client: WikimediaClient | None = None


def get_wikimedia_client() -> WikimediaClient:
    global _client
    if _client is None:
        _client = WikimediaClient()
    return _client


async def close_wikimedia_client() -> None:
    global _client
    if _client is not None:
        await _client.aclose()
        _client = None
