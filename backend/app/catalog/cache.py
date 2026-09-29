"""Redis cache pro syrové odpovědi z externích metadatových API.

Cílem je hlavně respektovat rate limity (MusicBrainz/Deezer) — opakovaný
dotaz na stejného interpreta/album během TTL okna nesahá ven vůbec. Sdílí
Redis instanci s provisioning frontou (app/redis_bus.py), jen ve vlastním
klíčovém prostoru.
"""

from __future__ import annotations

import json
from typing import Any, Awaitable, Callable

from app.redis_bus import get_redis

CACHE_PREFIX = "vault:catalog:cache:"


EMPTY_TTL_SECONDS = 10 * 60


async def cached_json(
    key: str,
    ttl_seconds: int,
    fetch: Callable[[], Awaitable[Any]],
    is_empty: Callable[[Any], bool] | None = None,
) -> Any:
    """`is_empty` -- prázdný výsledek (typicky krátký výpadek zdroje) se
    uloží jen na `EMPTY_TTL_SECONDS`, ne na celé TTL."""
    r = get_redis()
    cache_key = CACHE_PREFIX + key
    cached = await r.get(cache_key)
    if cached is not None:
        return json.loads(cached)

    value = await fetch()
    ttl = EMPTY_TTL_SECONDS if is_empty is not None and is_empty(value) else ttl_seconds
    await r.set(cache_key, json.dumps(value), ex=ttl)
    return value
