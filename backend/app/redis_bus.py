"""Centrální místo pro Redis připojení a jmenné konvence kanálů/streamu.

Jeden Redis instance nese dvě odlišné role, obě záměrně:
  - Stream `PROVISIONING_STREAM` + consumer group = fronta úloh (at-least-once,
    přežije restart workeru, umožňuje horizontální škálování).
  - Pub/sub kanál per-user = pouze "fire and forget" notifikace do WS
    vrstvy; když zrovna nikdo neposlouchá, událost se ztratí a to je v
    pořádku — trvalý stav (MediaAsset/ProvisioningJob) žije v DB, pub/sub
    je jen upozornění "něco se změnilo".
"""

from __future__ import annotations

import asyncio
import os

import redis.asyncio as redis

REDIS_URL = os.environ.get("REDIS_URL", "redis://redis:6379/0")

PROVISIONING_STREAM = "vault:provisioning:jobs"
# Skladba, na kterou uživatel právě klikl "Přehrát" -- workery tenhle stream
# čtou přednostně, ať nečeká za prefetchem celého alba v běžné frontě.
PROVISIONING_PRIORITY_STREAM = "vault:provisioning:jobs:priority"
PROVISIONING_GROUP = "vault:provisioning:workers"


def job_lock_key(job_id: str) -> str:
    return f"vault:provisioning:lock:{job_id}"


def job_escalate_key(job_id: str) -> str:
    """Nastavené, když uživatel chce skladbu HNED, ale její job už běží
    v pomalém (prefetch) režimu -- běžící worker podle toho přidá rychlou
    YouTube cestu."""
    return f"vault:provisioning:escalate:{job_id}"

_redis: redis.Redis | None = None
_redis_loop: asyncio.AbstractEventLoop | None = None


def get_redis() -> redis.Redis:
    """Vrací sdílený async Redis klient, svázaný s aktuální event loop.

    V produkci (uvicorn pro `api`, `asyncio.run(main())` pro `worker`) žije
    přesně jedna smyčka po celou dobu běhu procesu, takže se klient vytvoří
    jen jednou. Kontrola na `_redis_loop` je pojistka pro situace s více
    smyčkami v jednom procesu (testy, `asyncio.run` volaný opakovaně) — bez
    ní by starý klient po zániku své smyčky vyhazoval "Event loop is closed".
    """
    global _redis, _redis_loop
    loop = asyncio.get_running_loop()
    if _redis is None or _redis_loop is not loop:
        _redis = redis.from_url(REDIS_URL, decode_responses=True)
        _redis_loop = loop
    return _redis


_ratelimit_redis: redis.Redis | None = None
_ratelimit_loop: asyncio.AbstractEventLoop | None = None


def get_ratelimit_redis() -> redis.Redis:
    """Redis pro omezovače dotazů ven (Deezer, Last.fm, MusicBrainz).
    Testovací instance (`RATE_LIMIT_REDIS_URL`) sdílí frontu s ostrou --
    limity platí na IP serveru, ne na instanci."""
    global _ratelimit_redis, _ratelimit_loop
    url = os.environ.get("RATE_LIMIT_REDIS_URL") or ""
    if not url:
        return get_redis()
    loop = asyncio.get_running_loop()
    if _ratelimit_redis is None or _ratelimit_loop is not loop:
        _ratelimit_redis = redis.from_url(url, decode_responses=True)
        _ratelimit_loop = loop
    return _ratelimit_redis


def user_events_channel(user_id: str) -> str:
    return f"vault:events:user:{user_id}"
