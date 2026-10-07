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


# Single-flight: drahé studené sestavení (stránka kategorie 20-30 s) běží
# jednou -- souběžní volající v tomhle procesu čekají na stejný výsledek.
# Mezi procesy (api x worker) hlídá Redis zámek `lock:<klíč>`.
# Klíč i se smyčkou: future z jiné event loop (nástroj s vlastní
# `asyncio.run`) nejde čekat.
_inflight: dict[tuple[int, str], asyncio.Future] = {}
LOCK_SECONDS = 120
LOCK_WAIT_SECONDS = 60.0


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
    flight = (id(asyncio.get_running_loop()), cache_key)
    while True:
        cached = await r.get(cache_key)
        if cached is not None:
            return json.loads(cached)
        pending = _inflight.get(flight)
        if pending is None:
            break
        try:
            # shield: zrušení čekajícího (klient zavřel stránku) nesmí zrušit
            # sestavení ostatním.
            return await asyncio.shield(pending)
        except asyncio.CancelledError:
            if pending.cancelled():
                continue  # zrušil se ten, kdo sestavoval -> zkusit znovu
            raise

    future: asyncio.Future = asyncio.get_running_loop().create_future()
    _inflight[flight] = future
    try:
        value = await _build(r, cache_key, ttl_seconds, fetch, is_empty)
    except asyncio.CancelledError:
        future.cancel()
        raise
    except BaseException as exc:
        future.set_exception(exc)
        future.exception()  # nikdo nečeká -> žádné "exception never retrieved"
        raise
    else:
        future.set_result(value)
        return value
    finally:
        if _inflight.get(flight) is future:
            del _inflight[flight]


async def _build(r, cache_key: str, ttl_seconds: int, fetch, is_empty) -> Any:
    lock_key = "lock:" + cache_key
    try:
        got_lock = bool(await r.set(lock_key, "1", nx=True, ex=LOCK_SECONDS))
    except Exception:  # noqa: BLE001 - bez zámku prostě sestavit
        got_lock = True
    if not got_lock:
        # Sestavuje jiný proces -- počkat na jeho výsledek, po limitu
        # (spadl/trvá moc) sestavit sami.
        deadline = time.monotonic() + LOCK_WAIT_SECONDS
        while time.monotonic() < deadline:
            await asyncio.sleep(0.25)
            cached = await r.get(cache_key)
            if cached is not None:
                return json.loads(cached)
            if not await r.exists(lock_key):
                break
        cached = await r.get(cache_key)
        if cached is not None:
            return json.loads(cached)
    try:
        value = await fetch()
        ttl = EMPTY_TTL_SECONDS if is_empty is not None and is_empty(value) else ttl_seconds
        await r.set(cache_key, json.dumps(value), ex=ttl)
        return value
    finally:
        if got_lock:
            try:
                await r.delete(lock_key)
            except Exception:  # noqa: BLE001
                pass


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

    # Úplně poprvé: souběžné dotazy na stejný klíč čekají na jedno sestavení.
    flight = (id(asyncio.get_running_loop()), cache_key)
    pending = _inflight.get(flight)
    if pending is not None:
        return await asyncio.shield(pending)
    future: asyncio.Future = asyncio.get_running_loop().create_future()
    _inflight[flight] = future
    try:
        value = await fetch()
        await store(value)
    except BaseException as exc:
        future.set_exception(exc)
        future.exception()
        raise
    finally:
        _inflight.pop(flight, None)
    future.set_result(value)
    return value


async def clear_stale_locks() -> int:
    """Při startu API: zámky sestavení z procesu, který spadl/restartoval
    uprostřed práce, by dalšího volajícího drželi až `LOCK_WAIT_SECONDS`
    (změřeno 60 s na stránce interpreta po restartu). Smaže i zámek běžící
    ve workeru -- to stojí nanejvýš jedno zdvojené sestavení."""
    from app.redis_bus import get_redis

    r = get_redis()
    n = 0
    async for key in r.scan_iter(match="lock:" + CACHE_PREFIX + "*", count=500):
        n += await r.delete(key)
    return n

