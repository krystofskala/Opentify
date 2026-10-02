"""Přestaví osobní mixy profilu hned (po změně algoritmu), ne až zítra.

    python -m app.tools.rebuild_personal [user_id]
"""

from __future__ import annotations

import asyncio
import logging
import sys

from sqlmodel import Session

from app.auth import ADMIN_ID
from app.db import engine, init_db
from app.home import category_mixes as cm
from app.home import generators as g
from app.home import personal_mixes as pm
from app.models import HomeSnapshot


async def main(user_id: str) -> None:
    init_db()
    logging.basicConfig(level=logging.INFO)
    token = g.set_home_user(user_id)
    try:
        with Session(engine) as session:
            for key in ("personal:daily-mixes", "personal:discover-weekly"):
                row = session.get(HomeSnapshot, g._scoped(key))
                if row is not None:
                    session.delete(row)
            session.commit()
        for name, fn in (
            ("denní mixy", pm.build_daily_mixes),
            ("objevy týdne", pm.build_discover_weekly),
            ("styly", pm.build_styles),
            ("žánrové mixy", cm.build_home_category_mixes),
        ):
            try:
                print(name, await fn(), flush=True)
            except Exception as exc:  # noqa: BLE001
                print(name, "CHYBA", exc, flush=True)
    finally:
        g.reset_home_user(token)
    from app.home.service import invalidate_home_cache

    await invalidate_home_cache()


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else ADMIN_ID))
