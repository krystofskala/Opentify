"""Jednorázově doplní ISRC nahrávkám, které mají Deezer ID, ale ISRC ne.

ISRC je univerzální kód nahrávky -- export (TuneMyMusic) podle něj páruje
skladby na Spotify, Apple Music, Tidalu i YouTube Music přesněji než podle
názvu. Deezer ho uvádí u každé skladby. Spuštění:
`python -m app.tools.backfill_isrc` (pokračuje, kde skončil).
"""

from __future__ import annotations

import asyncio

from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.db import engine
from app.models import Recording

PAUSE_SECONDS = 0.15


async def main() -> None:
    with Session(engine) as session:
        todo = [
            (r.id, r.deezer_id)
            for r in session.exec(
                select(Recording).where(Recording.isrc.is_(None), Recording.deezer_id.is_not(None))  # type: ignore[union-attr]
            ).all()
        ]
    print(f"k doplnění {len(todo)}", flush=True)
    dz = get_deezer_client()
    done = 0
    for i, (rid, dzid) in enumerate(todo, 1):
        track = await dz.track(str(dzid))
        isrc = (track or {}).get("isrc")
        if isrc:
            with Session(engine) as session:
                rec = session.get(Recording, rid)
                if rec is not None and not rec.isrc:
                    rec.isrc = isrc
                    session.add(rec)
                    session.commit()
                    done += 1
        if i % 200 == 0:
            print(f"{i}/{len(todo)} doplněno {done}", flush=True)
        await asyncio.sleep(PAUSE_SECONDS)
    print(f"hotovo, doplněno {done}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
