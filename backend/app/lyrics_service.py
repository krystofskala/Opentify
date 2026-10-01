"""Text skladeb přes veřejné LRCLIB API (https://lrclib.net/docs) — stejný
vzor jako `app/catalog/deezer.py`: tenký httpx adaptér + cache přes
`app.catalog.cache.cached_json`, aby opakovaný dotaz na tutéž skladbu
(mini bar i Now Playing screen ji můžou chtít znovu ve stejné relaci) nešel
pokaždé ven.

Používáme `/api/search`, ne přesný `/api/get` (ten vyžaduje bitově přesnou
délku skladby) — lokální soubory mají délku v tazích často mírně jinou než
LRCLIB záznam (jiný encoder/tagger), takže striktní shoda by zbytečně
propadala.

Výběr kandidáta podle DÉLKY: dřív se bral první výsledek se synchronizovaným
textem, a to byla často jiná verze (live, remaster, klip s intrem) -- časování
pak nesedělo vůbec (živě nahlášeno). Synchronizovaný text se teď vrací jen
od kandidáta, jehož délka sedí s naším souborem (± `_SYNC_TOLERANCE_S`);
jinak radši jen prostý text bez časování než špatně časovaný.
"""

from __future__ import annotations

import os
import re
from typing import Any

import httpx

from app.catalog.cache import cached_json

LRCLIB_BASE_URL = os.environ.get("LRCLIB_API_BASE", "https://lrclib.net/api")
LYRICS_TTL_SECONDS = 7 * 24 * 60 * 60  # text skladby se nemění, týden je bezpečný

_NOT_FOUND = {"not_found": True}
_SYNC_TOLERANCE_S = 3.0

_client = httpx.AsyncClient(base_url=LRCLIB_BASE_URL, timeout=10.0)

# " - 2004 Remaster", " (Remastered 2011)", " [Live]", " (feat. X)" ...
_TITLE_NOISE = re.compile(
    r"\s*(?:-\s*(?:\d{4}\s*)?(?:remaster(?:ed)?|mono|stereo|single version|radio edit)[^-]*$"
    r"|[\(\[][^\)\]]*(?:remaster|feat\.|ft\.|version|edit|mono|stereo)[^\)\]]*[\)\]])",
    re.IGNORECASE,
)


def clean_title(title: str) -> str:
    cleaned = _TITLE_NOISE.sub("", title).strip()
    return cleaned or title


class _SourceDown(Exception):
    """LRCLIB neodpověděl -- výsledek se NEUKLÁDÁ (dřív se výpadek uložil
    jako "text neexistuje" na týden; živě: Hot Milk – Wide Awake)."""


async def _search(params: dict[str, Any]) -> list[dict[str, Any]]:
    try:
        resp = await _client.get("/search", params=params)
        resp.raise_for_status()
        results = resp.json()
    except (httpx.TransportError, httpx.HTTPStatusError, ValueError) as exc:
        raise _SourceDown from exc
    return results if isinstance(results, list) else []


_ovh = httpx.AsyncClient(base_url="https://api.lyrics.ovh/v1", timeout=10.0)


async def _lyrics_ovh(artist_name: str | None, track_name: str) -> dict[str, Any] | None:
    """Záložní zdroj (lyrics.ovh): jen prostý text bez časování."""
    if not artist_name:
        return None
    from urllib.parse import quote

    try:
        resp = await _ovh.get(f"/{quote(artist_name, safe='')}/{quote(clean_title(track_name), safe='')}")
        text = (resp.json().get("lyrics") or "").strip() if resp.status_code == 200 else ""
    except (httpx.HTTPError, ValueError):
        return None
    # lyrics.ovh občas začíná řádkem "Paroles de la chanson ..." -- pryč.
    text = re.sub(r"^Paroles de la chanson[^\n]*\n", "", text).strip()
    return {"plain": text, "synced": None, "instrumental": False, "source": "lyrics.ovh"} if text else None


def _pick(results: list[dict[str, Any]], duration_s: float | None) -> dict[str, Any] | None:
    synced = [r for r in results if r.get("syncedLyrics")]
    if duration_s is None:
        best = synced[0] if synced else None
    else:
        fitting = [r for r in synced if abs(float(r.get("duration") or 0) - duration_s) <= _SYNC_TOLERANCE_S]
        best = min(fitting, key=lambda r: abs(float(r.get("duration") or 0) - duration_s), default=None)
    if best is not None:
        return {
            "plain": best.get("plainLyrics"),
            "synced": best.get("syncedLyrics"),
            "instrumental": bool(best.get("instrumental")),
            "matchedDuration": best.get("duration"),
        }
    plain = next((r for r in results if r.get("plainLyrics")), None)
    if plain is None:
        instrumental = next((r for r in results if r.get("instrumental")), None)
        return {"plain": None, "synced": None, "instrumental": True} if instrumental else None
    return {"plain": plain.get("plainLyrics"), "synced": None, "instrumental": bool(plain.get("instrumental"))}


async def fetch_lyrics(
    *,
    track_name: str,
    artist_name: str | None,
    album_name: str | None,
    duration_s: float | None = None,
) -> dict[str, Any] | None:
    duration_key = "" if duration_s is None else str(round(duration_s))
    cache_key = f"lyrics:v3:{artist_name or ''}:{track_name}:{duration_key}"

    async def fetch() -> dict[str, Any]:
        params: dict[str, Any] = {"track_name": track_name}
        if artist_name:
            params["artist_name"] = artist_name
        if album_name:
            params["album_name"] = album_name
        results = await _search(params)
        picked = _pick(results, duration_s)
        if picked is None or picked.get("synced") is None:
            # Druhý pokus: bez alba (kompilace/reedice se v LRCLIB jmenují
            # jinak) a s očištěným názvem ("- 2004 Remaster" apod.).
            params = {"track_name": clean_title(track_name)}
            if artist_name:
                params["artist_name"] = artist_name
            more = await _search(params)
            seen = {r.get("id") for r in results}
            merged = results + [r for r in more if r.get("id") not in seen]
            picked = _pick(merged, duration_s) or picked
        if picked is None:
            picked = await _lyrics_ovh(artist_name, track_name)
        return picked or _NOT_FOUND

    try:
        # "Nenalezeno" jen na krátko (EMPTY_TTL) -- texty do LRCLIB přibývají.
        result = await cached_json(
            cache_key, LYRICS_TTL_SECONDS, fetch, is_empty=lambda v: bool(v and v.get("not_found"))
        )
    except _SourceDown:
        return None
    if result is None or result.get("not_found"):
        return None
    return result
