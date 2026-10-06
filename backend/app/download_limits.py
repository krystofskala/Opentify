"""Limity stahování na člověka (kamarádi přes Funnel nesmí zahltit disk ani
Soulseek). Admin je bez limitu. Počítá se jen NOVÉ stahování -- přehrávání
a už stažené věci ne.

- hudba: `MUSIC_PER_HOUR` / `MUSIC_PER_DAY` nově obstaraných skladeb,
- audioknihy: `BOOKS_GB_PER_WEEK` za 7 dní, jedna kniha nad
  `BOOK_MAX_GB_SELF` jen přes správce.
"""

from __future__ import annotations

import time
from datetime import timedelta

from fastapi import HTTPException
from sqlmodel import Session, func, select

from app.db import engine
from app.models import AppUser, SpokenBook
from app.notify import notify
from app.redis_bus import get_redis
from app.utils import utcnow

MUSIC_PER_HOUR = 60
MUSIC_PER_DAY = 300
BOOKS_GB_PER_WEEK = 20
BOOK_MAX_GB_SELF = 5
GB = 1024**3


def _user(user_id: str) -> AppUser | None:
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        if user is not None:
            session.expunge(user)
        return user


def is_admin(user_id: str) -> bool:
    user = _user(user_id)
    return user is not None and user.role == "admin"


def _name(user_id: str) -> str:
    user = _user(user_id)
    return user.name if user else user_id[:8]


async def check_music(user_id: str) -> None:
    """Před založením NOVÉHO stahování skladby. 429 = přes limit."""
    if is_admin(user_id):
        return
    r = get_redis()
    now = int(time.time())
    hour_key = f"dl-limit:music:{user_id}:h:{now // 3600}"
    day_key = f"dl-limit:music:{user_id}:d:{now // 86400}"
    hour = int(await r.get(hour_key) or 0)
    day = int(await r.get(day_key) or 0)
    if hour >= MUSIC_PER_HOUR or day >= MUSIC_PER_DAY:
        notify("📦 Limit stahování", f"{_name(user_id)}: {hour} nových skladeb za hodinu, {day} za den",
               tags=["package"], key=f"dl-limit:{user_id}", every_s=3600)
        raise HTTPException(
            status_code=429,
            detail="Dnes už jsi stáhl hodně nových skladeb. Už stažené hrají dál, nové zkus později.",
        )


async def count_music(user_id: str) -> None:
    """Po založení nového stahování."""
    if is_admin(user_id):
        return
    r = get_redis()
    now = int(time.time())
    for key, ttl in ((f"dl-limit:music:{user_id}:h:{now // 3600}", 3600), (f"dl-limit:music:{user_id}:d:{now // 86400}", 86400)):
        await r.incr(key)
        await r.expire(key, ttl)


def check_book(user_id: str, size_bytes: int | None) -> None:
    """Před stažením audioknihy (sync -- jen DB)."""
    if is_admin(user_id):
        return
    size = size_bytes or 0
    if size > BOOK_MAX_GB_SELF * GB:
        notify("📚 Žádost o velkou audioknihu", f"{_name(user_id)}: {size / GB:.1f} GB – stáhnout můžeš ty",
               tags=["books"], key=f"book-big:{user_id}", every_s=600)
        raise HTTPException(
            status_code=403,
            detail=f"Tohle vydání má přes {BOOK_MAX_GB_SELF} GB – požádej správce, ať ho stáhne.",
        )
    since = utcnow() - timedelta(days=7)
    with Session(engine) as session:
        used = session.exec(
            select(func.coalesce(func.sum(SpokenBook.size_bytes), 0)).where(
                SpokenBook.requested_by_user_id == user_id, SpokenBook.created_at >= since
            )
        ).one()
    if used + size > BOOKS_GB_PER_WEEK * GB:
        notify("📚 Limit audioknih", f"{_name(user_id)}: {used / GB:.1f} GB za týden",
               tags=["books"], key=f"book-limit:{user_id}", every_s=3600)
        raise HTTPException(
            status_code=429,
            detail=f"Za poslední týden už máš stažené audioknihy za {used / GB:.0f} GB (limit {BOOKS_GB_PER_WEEK} GB).",
        )
