"""Jednorázově: "alba", která mají ve skutečnosti 1-3 skladby (singly) nebo
4-6 krátkých (EP), u interpretů, které uživatel poslouchá. Načte tracklist
každého takového alba (`get_release_tracks` typ sám opraví, viz
`CatalogService._fix_release_type`). Jinak se to děje líně až při otevření
alba -- stránka interpreta by do té doby řadila singly mezi alba.

Spuštění (v kontejneru api, běží ~hodinu kvůli limitu MusicBrainz):
    python -m app.tools.backfill_release_types
"""

from __future__ import annotations

import asyncio

from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.musicbrainz import get_musicbrainz_client
from app.catalog.service import CatalogService
from app.db import engine
from app.models import MediaAsset, Recording, Release


async def main() -> None:
    with Session(engine) as session:
        artists = set(
            session.exec(select(Recording.artist_id).join(MediaAsset, MediaAsset.recording_id == Recording.id)).all()
        )
        ids = [
            r.id
            for r in session.exec(select(Release).where(Release.release_type == "album")).all()
            if r.artist_id in artists and (r.mbid or r.deezer_id) and not (r.external_refs or {}).get("typeByTracks")
        ]
    print(f"alb ke kontrole: {len(ids)}", flush=True)
    fixed = 0
    for i, release_id in enumerate(ids, 1):
        with Session(engine) as session:
            service = CatalogService(session, get_musicbrainz_client(), get_deezer_client())
            try:
                await service.get_release_tracks(release_id)
            except Exception as exc:  # noqa: BLE001 - jedno album nezastaví zbytek
                print(f"{release_id}: {type(exc).__name__}: {exc}", flush=True)
                continue
            release = session.get(Release, release_id)
            new_type = (release.external_refs or {}).get("typeByTracks") if release else None
            if new_type:
                fixed += 1
                print(f"{new_type}: {release.title}", flush=True)
        if i % 100 == 0:
            print(f"{i}/{len(ids)}, opraveno {fixed}", flush=True)
    print(f"hotovo: opraveno {fixed} z {len(ids)}", flush=True)
    # Diskografie jsou v cache (SWR, den) -- bez smazání by se změna ukázala až zítra.
    from app.redis_bus import get_redis

    r = get_redis()
    keys = [k async for k in r.scan_iter(match="vault:catalog:cache:swr:discography:*")]
    if keys:
        await r.delete(*keys)
    print(f"smazáno {len(keys)} diskografií z cache", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
