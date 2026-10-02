"""Poslouchá teď někdo jiný než admin? Před restartem API / nasazením.

    python -m app.tools.activity   # exit 0 = volno, 1 = někdo poslouchá

Zdroje: stav přehrávání z Opentify Connect (realtime hub ho drží v Redisu,
`connect:playing:<user>`), a poslechy za posledních 10 minut (pro jistotu,
kdyby zařízení nebylo připojené přes WebSocket).
"""

from __future__ import annotations

import asyncio
import sys
from datetime import timedelta

from sqlmodel import Session, select

from app.auth import ADMIN_ID
from app.db import engine
from app.models import AppUser, Listen
from app.redis_bus import get_redis
from app.utils import utcnow

RECENT = timedelta(minutes=10)


async def busy_profiles() -> list[str]:
    r = get_redis()
    names: dict[str, str] = {}
    with Session(engine) as session:
        for u in session.exec(select(AppUser)).all():
            names[u.id] = u.name
        cutoff = utcnow() - RECENT
        recent = set(session.exec(select(Listen.user_id).where(Listen.played_at >= cutoff)).all())
    busy = []
    for user_id, name in names.items():
        if user_id == ADMIN_ID:
            continue
        playing = await r.get(f"connect:playing:{user_id}")
        if playing == "1" or user_id in recent:
            busy.append(name)
    await r.aclose()
    return busy


def main() -> int:
    busy = asyncio.run(busy_profiles())
    if busy:
        print("poslouchá:", ", ".join(busy))
        return 1
    print("volno")
    return 0


if __name__ == "__main__":
    sys.exit(main())
