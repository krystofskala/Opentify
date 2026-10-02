"""Přestaví řady všech žánrů hned (ne až při denní obnově) -- po změně zdrojů.

    python -m app.tools.rebuild_genre_rails
"""

from __future__ import annotations

import asyncio

from app.browse import CATEGORIES, genre_rail
from app.db import init_db


async def main() -> None:
    init_db()
    for c in CATEGORIES:
        try:
            playlist_id = await genre_rail(c, force=True)
            print(f"{c.id}: {playlist_id}", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"{c.id}: CHYBA {exc}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
