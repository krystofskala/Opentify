"""Ohlásit plánovaný restart serveru všem appkám (hláška „Opentify se teď na
chvilku aktualizuje…“), ať ho nikdo nebere jako chybu. Pouští se těsně před
`docker compose up -d --build api` (viz postup nasazení):

    python -m app.tools.announce_restart
"""

from __future__ import annotations

import asyncio

from sqlmodel import Session, select

from app.db import engine
from app.events import publish_event
from app.models import AppUser


async def main() -> int:
    with Session(engine) as session:
        users = list(session.exec(select(AppUser.id)).all())
    for user_id in users:
        await publish_event(user_id, "server.restarting", {})
    # Chvilka, ať zpráva doputuje přes Redis k zařízením dřív, než API spadne.
    await asyncio.sleep(2)
    return len(users)


if __name__ == "__main__":
    print(f"ohlášeno {asyncio.run(main())} profilům")
