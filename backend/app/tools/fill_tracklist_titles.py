"""Doplní `tracklistTitles` (názvy kanonické edice) albům, které jsou
v knihovně -- Knihovna › Alba › "Celá alba" podle nich pozná úplná alba.
Načte tracklist stejně jako stránka alba (MusicBrainz přes sdílenou frontu,
z cache bez čekání).

    python -m app.tools.fill_tracklist_titles"""
from __future__ import annotations

import asyncio

from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.musicbrainz import get_musicbrainz_client
from app.catalog.service import CatalogService
from app.db import engine
from app.models import MediaAsset, MediaAssetStatus, Recording, Release


async def main() -> None:
    with Session(engine) as session:
        ids = session.exec(
            select(Release.id, Release.external_refs)
            .join(Recording, Recording.release_id == Release.id)
            .join(MediaAsset, MediaAsset.recording_id == Recording.id)
            .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
            .distinct()
        ).all()
    todo = [rid for rid, refs in ids if not (refs or {}).get("tracklistTitles")]
    print(f"alba bez názvů tracklistu: {len(todo)} z {len(ids)}", flush=True)
    for n, rid in enumerate(todo, 1):
        try:
            with Session(engine) as session:
                await CatalogService(session, get_musicbrainz_client(), get_deezer_client()).get_release_tracks(rid)
                session.commit()
        except Exception as exc:  # noqa: BLE001
            print(f"  {rid}: {exc}", flush=True)
        if n % 100 == 0:
            print(f"  {n}/{len(todo)}", flush=True)
    print("hotovo", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
