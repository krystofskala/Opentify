"""Smaže z katalogu obrázky z Deezeru, které jsou jen výchozí šedá silueta
("bez fotky"). Deezer u interpretů/alb bez obrázku (nebo s odebraným)
přesměruje na `/images/<typ>/d41d8cd98f00b204e9800998ecf8427e/...` (md5
prázdného souboru) -- appka pak místo zástupného obalu ukazovala šedou
postavu (živě nahlášeno). Spuštění: python -m app.tools.drop_deezer_placeholders
"""

from __future__ import annotations

import asyncio

import httpx
from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, Release

EMPTY = "d41d8cd98f00b204e9800998ecf8427e"


async def _is_placeholder(client: httpx.AsyncClient, url: str) -> bool:
    if EMPTY in url:
        return True
    try:
        r = await client.head(url, follow_redirects=False)
    except httpx.HTTPError:
        return False
    return EMPTY in (r.headers.get("location") or "")


async def main() -> None:
    with Session(engine) as session:
        rows: list[tuple[type, str, str]] = []
        for model in (Artist, Release):
            for row in session.exec(select(model)).all():
                first = (row.images or [None])[0]
                if first and "dzcdn.net" in first:
                    rows.append((model, row.id, first))
    print(f"ke kontrole: {len(rows)}", flush=True)
    sem = asyncio.Semaphore(16)
    bad: list[tuple[type, str]] = []
    async with httpx.AsyncClient(timeout=15, headers={"User-Agent": "Opentify/1.0"}) as client:

        async def check(model, row_id, url):
            async with sem:
                if await _is_placeholder(client, url):
                    bad.append((model, row_id))

        await asyncio.gather(*(check(*r) for r in rows))
    with Session(engine) as session:
        for model, row_id in bad:
            row = session.get(model, row_id)
            if row is not None:
                row.images = [u for u in (row.images or []) if "dzcdn.net" not in u]
                session.add(row)
        session.commit()
    print(f"smazáno výchozích siluet: {len(bad)} "
          f"(interpreti {sum(1 for m, _ in bad if m is Artist)}, alba {sum(1 for m, _ in bad if m is Release)})", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
