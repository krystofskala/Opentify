"""Async rate limiter pro externí API (MusicBrainz 1 req/s, Deezer, ListenBrainz).

Limity platí na NAŠI IP adresu, ne na proces -- a MusicBrainz volá API, každý
worker i nástroje na pozadí (backfill_*), každý ve vlastním procesu. Dřív měl
každý proces vlastní zámek, takže dohromady mohlo odejít několik požadavků za
sekundu (víc uživatelů naráz = jen horší). Proto se pořadí rezervuje
centrálně v Redisu: každé volání si atomicky (Lua) zabere další volný slot
`max(teď, poslední + interval)` a do něj počká. Hodiny bere Redis (`TIME`),
takže nevadí rozdíly mezi kontejnery. Když Redis není dostupný, spadne se na
místní zámek v procesu (původní chování).
"""

from __future__ import annotations

import asyncio
import logging
import time

logger = logging.getLogger(__name__)

# Vrátí čekání v sekundách (jako text -- Lua by číslo usekla na celé),
# nebo "-1", když by se čekalo déle než `maxwait` (pak se slot nezabere).
_RESERVE = """
local t = redis.call('TIME')
local now = tonumber(t[1]) + tonumber(t[2]) / 1000000
local interval = tonumber(ARGV[1])
local maxwait = tonumber(ARGV[2])
local last = tonumber(redis.call('GET', KEYS[1]) or '0')
local slot = math.max(now, last + interval)
if maxwait >= 0 and slot - now > maxwait then
  return '-1'
end
redis.call('SET', KEYS[1], string.format('%.6f', slot), 'PX', math.ceil((slot - now + interval) * 1000) + 1000)
return string.format('%.6f', slot - now)
"""


class RateLimitBusy(Exception):
    """Ve frontě už čeká příliš mnoho volání -- volající má selhat hned,
    místo aby desítky vteřin držel DB spojení (živě: psaní do hledání
    vyčerpalo pool 5+10 spojení a celá appka přestala načítat)."""


class AsyncRateLimiter:
    def __init__(self, min_interval_seconds: float, max_waiters: int | None = None, key: str | None = None) -> None:
        self._min_interval = min_interval_seconds
        self._lock = asyncio.Lock()
        self._last_call = 0.0
        self._max_waiters = max_waiters
        self._waiters = 0
        # Sdílený limit napříč procesy (Redis); None = jen v rámci procesu.
        self._key = f"vault:ratelimit:{key}" if key else None
        self._redis_failed_at = 0.0

    async def wait(self) -> None:
        if self._key is not None and time.monotonic() - self._redis_failed_at > 30:
            try:
                await self._wait_shared()
                return
            except RateLimitBusy:
                raise
            except Exception as exc:  # Redis nedostupný -> místní limit, za 30 s zkusit znovu
                self._redis_failed_at = time.monotonic()
                logger.warning("rate limit %s: Redis nedostupný (%s), jen místní limit", self._key, exc)
        await self._wait_local()

    async def _wait_shared(self) -> None:
        from app.redis_bus import get_redis

        # Stejná hranice jako místní `max_waiters`: víc než N intervalů čekání
        # = uživatel to nepočká, selhat hned.
        maxwait = -1.0 if self._max_waiters is None else self._max_waiters * self._min_interval
        delay = float(await get_redis().eval(_RESERVE, 1, self._key, str(self._min_interval), str(maxwait)))
        if delay < 0:
            raise RateLimitBusy()
        if delay > 0:
            await asyncio.sleep(delay)

    async def _wait_local(self) -> None:
        if self._max_waiters is not None and self._waiters >= self._max_waiters:
            raise RateLimitBusy()
        self._waiters += 1
        try:
            async with self._lock:
                now = time.monotonic()
                elapsed = now - self._last_call
                if elapsed < self._min_interval:
                    await asyncio.sleep(self._min_interval - elapsed)
                self._last_call = time.monotonic()
        finally:
            self._waiters -= 1
