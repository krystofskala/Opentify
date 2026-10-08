"""Last.fm API (https://www.last.fm/api) -- veřejná data pro všechny profily
(oprava překlepů v hledání, žánrové štítky, podobní interpreti, počty
poslechů) a scrobblování jen za profil, který si připojil vlastní účet.

Klíč appky `LASTFM_API_KEY` (+ `LASTFM_API_SECRET` jen pro podepsané volání:
přihlášení a scrobble) je v `.env`. Bez klíče vrací všechno prázdné/None --
zbytek appky jede dál z Deezeru a ListenBrainz.

Limit Last.fm je ~5 req/s na klíč: sdílený limiter přes Redis (víc procesů)
a odpovědi v Redis cache.
"""

from __future__ import annotations

import hashlib
import os
from typing import Any

import httpx

from app.catalog.cache import cached_json
from app.catalog.rate_limit import AsyncRateLimiter, RateLimitBusy

API = "https://ws.audioscrobbler.com/2.0/"
DAY = 24 * 60 * 60

_http = httpx.AsyncClient(timeout=10.0, headers={"User-Agent": "Opentify/1.0"})
_limiter = AsyncRateLimiter(0.25, max_waiters=40, key="lastfm")


def api_key() -> str | None:
    return os.environ.get("LASTFM_API_KEY") or None


def api_secret() -> str | None:
    return os.environ.get("LASTFM_API_SECRET") or None


class LastfmError(RuntimeError):
    pass


async def _call(params: dict[str, str]) -> dict[str, Any] | None:
    key = api_key()
    if not key:
        return None
    try:
        await _limiter.wait()
        resp = await _http.get(API, params={**params, "api_key": key, "format": "json"})
        data = resp.json()
    except (httpx.HTTPError, ValueError, RateLimitBusy):
        return None
    if not isinstance(data, dict) or data.get("error"):
        return None
    return data


def _cache_key(params: dict[str, str]) -> str:
    return "lastfm:" + "&".join(f"{k}={v}" for k, v in sorted(params.items()))


async def get(params: dict[str, str], ttl: int = DAY) -> dict[str, Any] | None:
    """Nepodepsané čtení s cache. Výpadek se necachuje na celé TTL."""
    if not api_key():
        return None
    key = _cache_key(params)

    async def fetch() -> dict[str, Any]:
        return (await _call(params)) or {}

    data = await cached_json(key, ttl, fetch, is_empty=lambda v: not v)
    return data or None


def _sign(params: dict[str, str]) -> str:
    secret = api_secret() or ""
    raw = "".join(f"{k}{v}" for k, v in sorted(params.items()) if k not in ("format", "callback")) + secret
    return hashlib.md5(raw.encode("utf-8")).hexdigest()  # noqa: S324 -- tak to Last.fm chce


async def signed(params: dict[str, str], *, post: bool = False) -> dict[str, Any]:
    """Podepsané volání (přihlášení, scrobble). Vyhodí LastfmError."""
    key, secret = api_key(), api_secret()
    if not key or not secret:
        raise LastfmError("Last.fm není nastavené (LASTFM_API_KEY / LASTFM_API_SECRET)")
    body = {**params, "api_key": key}
    body["api_sig"] = _sign(body)
    body["format"] = "json"
    try:
        await _limiter.wait()
        resp = await (_http.post(API, data=body) if post else _http.get(API, params=body))
        data = resp.json()
    except (httpx.HTTPError, ValueError, RateLimitBusy) as exc:
        raise LastfmError(f"Last.fm nedostupné: {exc}") from exc
    if not isinstance(data, dict) or data.get("error"):
        raise LastfmError(str((data or {}).get("message") or "chyba Last.fm"))
    return data


def _as_list(value: Any) -> list[dict[str, Any]]:
    if isinstance(value, list):
        return [v for v in value if isinstance(v, dict)]
    if isinstance(value, dict):
        return [value]
    return []


def _int(value: Any) -> int | None:
    try:
        return int(value) or None
    except (TypeError, ValueError):
        return None


# --- Veřejná data ---------------------------------------------------------


async def artist_correction(name: str) -> str | None:
    """Správně napsané jméno interpreta ("bily strngs" -> "Billy Strings",
    "radiohed" -> "Radiohead"). `artist.getCorrection` vrací i neexistující
    varianty, takže hledání: nejposlouchanější výsledek, když má aspoň 50x
    víc posluchačů než ten se jménem přesně podle dotazu ("kontrast" tak
    zůstane Kontrast, ne High Contrast)."""
    import re
    import unicodedata

    def key(text: str) -> str:
        text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().casefold()
        return re.sub(r"[^a-z0-9]+", "", text)

    found = await search_artists(name, limit=8)
    if not found:
        return None
    best = max(found, key=lambda a: a.get("listeners") or 0)
    wanted = key(name)
    if key(best["name"]) == wanted:
        return None
    exact = max((a.get("listeners") or 0 for a in found if key(a["name"]) == wanted), default=0)
    if (best.get("listeners") or 0) >= max(50 * exact, 1000):
        return best["name"]
    return None


async def search_artists(query: str, limit: int = 10) -> list[dict[str, Any]]:
    data = await get({"method": "artist.search", "artist": query.strip(), "limit": str(limit)}, ttl=DAY)
    matches = ((data or {}).get("results") or {}).get("artistmatches") or {}
    return [
        {"name": a.get("name"), "mbid": a.get("mbid") or None, "listeners": _int(a.get("listeners"))}
        for a in _as_list(matches.get("artist"))
        if a.get("name")
    ]


async def search_tracks(query: str, limit: int = 10) -> list[dict[str, Any]]:
    data = await get({"method": "track.search", "track": query.strip(), "limit": str(limit)}, ttl=DAY)
    matches = ((data or {}).get("results") or {}).get("trackmatches") or {}
    return [
        {"title": t.get("name"), "artist": t.get("artist"), "listeners": _int(t.get("listeners"))}
        for t in _as_list(matches.get("track"))
        if t.get("name") and t.get("artist")
    ]


async def artist_info(name: str) -> dict[str, Any] | None:
    data = await get({"method": "artist.getinfo", "artist": name, "autocorrect": "1"}, ttl=DAY)
    artist = (data or {}).get("artist")
    if not isinstance(artist, dict):
        return None
    stats = artist.get("stats") or {}
    return {
        "name": artist.get("name"),
        "listeners": _int(stats.get("listeners")),
        "playcount": _int(stats.get("playcount")),
        "tags": [t.get("name") for t in _as_list((artist.get("tags") or {}).get("tag")) if t.get("name")],
    }


async def artist_top_tags(name: str, limit: int = 12) -> list[tuple[str, int]]:
    """Štítky interpreta i s vahou 0-100 (getinfo dává jen 5 bez vah --
    úzké styly jako "bluegrass" nebo "shoegaze" tak zapadaly pod "indie")."""
    data = await get({"method": "artist.gettoptags", "artist": name, "autocorrect": "1"}, ttl=7 * DAY)
    tags = _as_list(((data or {}).get("toptags") or {}).get("tag"))
    return [(t["name"], _int(t.get("count")) or 0) for t in tags if t.get("name")][:limit]


def _track_tags_params(artist: str, title: str) -> dict[str, str]:
    return {"method": "track.gettoptags", "artist": artist, "track": title, "autocorrect": "1"}


async def track_top_tags(artist: str, title: str, *, cached_only: bool = False) -> list[tuple[str, int]] | None:
    """Štítky skladby s vahou 0-100 (nálady: sad, chill, workout…). Měsíc
    v cache. `cached_only` = jen z cache, bez dotazu (skládání mixů nesmí
    čekat na stovky dotazů; plní je `app/home/mood_tracks.warm`); `None` =
    v cache ještě není."""
    params = _track_tags_params(artist, title)
    if cached_only:
        import json

        from app.catalog.cache import CACHE_PREFIX
        from app.redis_bus import get_redis

        raw = await get_redis().get(CACHE_PREFIX + _cache_key(params))
        if raw is None:
            return None
        data = json.loads(raw) or {}  # uložené prázdné = zjišťovalo se, štítky nemá
    else:
        data = await get(params, ttl=30 * DAY)
    tags = _as_list(((data or {}).get("toptags") or {}).get("tag"))
    return [(t["name"], _int(t.get("count")) or 0) for t in tags if t.get("name")][:20]


async def track_album(artist: str, title: str) -> str | None:
    """Album, ze kterého se skladba na Last.fm nejvíc poslouchá."""
    data = await get({"method": "track.getinfo", "artist": artist, "track": title, "autocorrect": "1"}, ttl=7 * DAY)
    album = ((data or {}).get("track") or {}).get("album") or {}
    return album.get("title") or None


async def similar_artists(name: str, limit: int = 20) -> list[dict[str, Any]]:
    data = await get(
        {"method": "artist.getsimilar", "artist": name, "autocorrect": "1", "limit": str(limit)}, ttl=7 * DAY
    )
    return [
        {"name": a.get("name"), "mbid": a.get("mbid") or None, "match": float(a.get("match") or 0)}
        for a in _as_list(((data or {}).get("similarartists") or {}).get("artist"))
        if a.get("name")
    ]


async def similar_tracks(artist: str, title: str, limit: int = 30) -> list[dict[str, Any]]:
    data = await get(
        {"method": "track.getsimilar", "artist": artist, "track": title, "autocorrect": "1", "limit": str(limit)},
        ttl=7 * DAY,
    )
    return [
        {"title": t.get("name"), "artist": (t.get("artist") or {}).get("name"), "match": float(t.get("match") or 0)}
        for t in _as_list(((data or {}).get("similartracks") or {}).get("track"))
        if t.get("name") and (t.get("artist") or {}).get("name")
    ]


async def artist_top_tracks(name: str, limit: int = 60) -> list[dict[str, Any]]:
    """Nejposlouchanější skladby interpreta na Last.fm (pořadí = popularita)."""
    data = await get(
        {"method": "artist.gettoptracks", "artist": name, "autocorrect": "1", "limit": str(limit)}, ttl=DAY
    )
    return [
        {"title": t.get("name"), "artist": (t.get("artist") or {}).get("name") or name, "playcount": _int(t.get("playcount"))}
        for t in _as_list(((data or {}).get("toptracks") or {}).get("track"))
        if t.get("name")
    ]


async def top_albums(name: str, limit: int = 30) -> list[dict[str, Any]]:
    data = await get(
        {"method": "artist.gettopalbums", "artist": name, "autocorrect": "1", "limit": str(limit)}, ttl=DAY
    )
    return [
        {"title": a.get("name"), "playcount": _int(a.get("playcount"))}
        for a in _as_list(((data or {}).get("topalbums") or {}).get("album"))
        if a.get("name")
    ]


async def tag_top_tracks(tag: str, limit: int = 50) -> list[dict[str, Any]]:
    data = await get({"method": "tag.gettoptracks", "tag": tag, "limit": str(limit)}, ttl=DAY)
    return [
        {"title": t.get("name"), "artist": (t.get("artist") or {}).get("name")}
        for t in _as_list(((data or {}).get("tracks") or {}).get("track"))
        if t.get("name") and (t.get("artist") or {}).get("name")
    ]


async def tag_top_artists(tag: str, limit: int = 30) -> list[str]:
    data = await get({"method": "tag.gettopartists", "tag": tag, "limit": str(limit)}, ttl=DAY)
    return [a["name"] for a in _as_list(((data or {}).get("topartists") or {}).get("artist")) if a.get("name")]


async def tag_top_albums(tag: str, limit: int = 30) -> list[dict[str, str]]:
    data = await get({"method": "tag.gettopalbums", "tag": tag, "limit": str(limit)}, ttl=DAY)
    return [
        {"title": a["name"], "artist": (a.get("artist") or {}).get("name") or ""}
        for a in _as_list(((data or {}).get("albums") or {}).get("album"))
        if a.get("name") and (a.get("artist") or {}).get("name")
    ]


async def tag_summary(tag: str) -> str | None:
    """Krátký popis žánru z Last.fm wiki (bez HTML a odkazu "Read more")."""
    import html
    import re

    data = await get({"method": "tag.getinfo", "tag": tag}, ttl=7 * DAY)
    text = (((data or {}).get("tag") or {}).get("wiki") or {}).get("summary") or ""
    text = re.sub(r"<a [^>]*>Read more on Last\.fm</a>\.?", "", text)
    text = html.unescape(re.sub(r"<[^>]+>", "", text)).strip()
    return text or None
