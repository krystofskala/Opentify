"""Doplní obsazení (víc hlavních interpretů) u alb v katalogu, která ho
ještě nemají zkontrolované (`creditsChecked`):

- alba jen z Deezeru: detail alba -> hlavní účinkující (`main_credits`),
- alba z MusicBrainz: artist-credit skupiny vydání (`_store_credits`).

Pomalu, ať nepřetíží Deezer (limit 50 dotazů / 5 s) ani MusicBrainz
(1 / s, sdílený se stahováním). Dá se kdykoli přerušit -- hotová alba mají
`creditsChecked` a příště se přeskočí.

    python -m app.tools.backfill_credits [--deezer-only] [--limit N]
"""

from __future__ import annotations

import asyncio
import logging
import sys

from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.deezer_ingest import apply_credits, main_credits
from app.catalog.identity import is_own_id
from app.catalog.musicbrainz import MusicBrainzError, get_musicbrainz_client
from app.catalog.service import CatalogService
from app.db import engine
from app.models import Release

logger = logging.getLogger("uvicorn.error")


def _todo(mb: bool) -> list[str]:
    with Session(engine) as session:
        rows = session.exec(select(Release)).all()
        out = []
        for r in rows:
            refs = r.external_refs or {}
            if refs.get("creditsChecked") or refs.get("source") in ("youtube", "soundcloud", "manual"):
                continue
            if is_own_id(r.mbid) or is_own_id(r.deezer_id):
                continue
            if mb and r.mbid:
                out.append(r.id)
            elif not mb and not r.mbid and r.deezer_id and r.deezer_id.isdigit():
                out.append(r.id)
        return out


async def run(deezer_only: bool, limit: int | None) -> None:
    dz = get_deezer_client()
    done = found = 0
    for rid in _todo(mb=False)[:limit]:
        with Session(engine) as session:
            release = session.get(Release, rid)
            album = await dz.album(release.deezer_id) if release else None
            if release is not None and album is not None:
                if apply_credits(release, main_credits(session, album.get("contributors") or []), release.artist_id):
                    session.add(release)
                    session.commit()
                found += bool((release.external_refs or {}).get("credits"))
        done += 1
        if done % 500 == 0:
            print(f"Deezer: {done} alb, spolupráce {found}", flush=True)
        await asyncio.sleep(0.15)
    print(f"Deezer hotovo: {done} alb, spolupráce {found}", flush=True)
    if deezer_only:
        return
    mb = get_musicbrainz_client()
    done = found = 0
    for rid in _todo(mb=True)[:limit]:
        with Session(engine) as session:
            release = session.get(Release, rid)
            if release is None:
                continue
            try:
                data = await mb.get_release_group(release.mbid)
            except MusicBrainzError:
                await asyncio.sleep(5)
                continue
            CatalogService(session, mb, dz)._store_credits(release, data.get("artist-credit") or [])
            found += bool((release.external_refs or {}).get("credits"))
        done += 1
        if done % 200 == 0:
            print(f"MusicBrainz: {done} alb, spolupráce {found}", flush=True)
        await asyncio.sleep(1.2)
    print(f"MusicBrainz hotovo: {done} alb, spolupráce {found}", flush=True)


def main() -> None:
    limit = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else None
    asyncio.run(run("--deezer-only" in sys.argv, limit))


if __name__ == "__main__":
    main()
