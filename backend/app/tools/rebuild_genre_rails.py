"""Přestaví řady všech žánrů hned (ne až při denní obnově) -- po změně zdrojů.

    python -m app.tools.rebuild_genre_rails
"""

from __future__ import annotations

import asyncio
import sys

from app.browse import CATEGORIES, build_showcase, genre_rail
from app.db import init_db


async def main() -> None:
    init_db()
    for c in CATEGORIES:
        try:
            playlist_id = await genre_rail(c, force="--showcase" not in sys.argv)
            print(f"{c.id}: {playlist_id}", flush=True)
            if c.group == "genre" and "--showcase" in sys.argv:
                await build_showcase(c)
                print(f"{c.id}: vitrína", flush=True)
        except Exception as exc:  # noqa: BLE001
            print(f"{c.id}: CHYBA {exc}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
