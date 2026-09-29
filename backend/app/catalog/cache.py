"""Redis cache pro syrové odpovědi z externích metadatových API.

Cílem je hlavně respektovat rate limity (MusicBrainz/Deezer) — opakovaný
dotaz na stejného interpreta/album během TTL okna nesahá ven vůbec. Sdílí
Redis instanci s provisioning frontou (app/redis_bus.py), jen ve vlastním
klíčovém prostoru.
"""

from __future__ import annotations

import asyncio
import json
import time
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


_refreshing: set[str] = set()


async def cached_json_swr(
    key: str,
    fresh_seconds: int,
    fetch: Callable[[], Awaitable[Any]],
    keep_seconds: int = 30 * 24 * 60 * 60,
) -> Any:
    """Stale-while-revalidate: uloženou hodnotu vrátí HNED; je-li starší než
    `fresh_seconds`, obnoví ji na pozadí (pro příští dotaz). Čeká se jen
    napoprvé. `fetch` nesmí záviset na objektech požadavku (DB session),
    běží i po odeslání odpovědi. `None` se neukládá."""
    r = get_redis()
    cache_key = CACHE_PREFIX + "swr:" + key

    async def store(value: Any) -> None:
        if value is not None:
            await r.set(cache_key, json.dumps({"at": time.time(), "value": value}), ex=keep_seconds)

    raw = await r.get(cache_key)
    if raw is not None:
        envelope = json.loads(raw)
        if time.time() - envelope.get("at", 0) > fresh_seconds and key not in _refreshing:
            _refreshing.add(key)

            async def refresh() -> None:
                try:
                    await store(await fetch())
                except Exception:  # noqa: BLE001 - obnova na pozadí, stará hodnota platí dál
                    pass
                finally:
                    _refreshing.discard(key)

            asyncio.get_running_loop().create_task(refresh())
        return envelope.get("value")

    value = await fetch()
    await store(value)
    return value
