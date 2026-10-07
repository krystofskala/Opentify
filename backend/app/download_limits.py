"""Limity stahování na člověka (kamarádi přes Funnel nesmí zahltit disk ani
Soulseek). Admin je bez limitu. Počítá se jen NOVÉ stahování -- přehrávání
a už stažené věci ne.

- hudba: `MUSIC_PER_HOUR` / `MUSIC_PER_DAY` nově obstaraných skladeb,
- audioknihy: nad `BOOKS_GB_PER_WEEK` za 7 dní, jedna kniha nad
  `BOOK_MAX_GB_SELF` a cokoli z internetu -> žádost o schválení
  (app/download_requests.py).
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

# Volně: rychlé přetáčení stahuje skladbu i tu další -- limit má zastavit
# jen hromadné stahování katalogu, ne divoké poslouchání (Kryštof 7. 10.).
MUSIC_PER_HOUR = 300
MUSIC_PER_DAY = 1500
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
            detail="Teď už jsi stáhl hodně nových skladeb. Už stažené hrají dál, nové zkus později.",
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


def book_approval_reason(user_id: str, size_bytes: int | None, *, public: bool) -> str | None:
    """Proč tuhle audioknihu musí schválit správce (None = může hned).
    Admin nikdy; z internetu vždy; jinak velké vydání nebo přes týdenní limit."""
    if is_admin(user_id):
        return None
    size = size_bytes or 0
    if public:
        return "z internetu"
    if size > BOOK_MAX_GB_SELF * GB:
        return f"velké vydání ({size / GB:.1f} GB)"
    since = utcnow() - timedelta(days=7)
    with Session(engine) as session:
        used = session.exec(
            select(func.coalesce(func.sum(SpokenBook.size_bytes), 0)).where(
                SpokenBook.requested_by_user_id == user_id, SpokenBook.created_at >= since
            )
        ).one()
    if used + size > BOOKS_GB_PER_WEEK * GB:
        return f"přes týdenní limit (už {used / GB:.1f} GB z {BOOKS_GB_PER_WEEK} GB)"
    return None
