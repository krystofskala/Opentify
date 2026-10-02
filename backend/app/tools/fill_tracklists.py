"""Doplní tracklisty alb z knihovny (kvůli filtru "Jen celá alba").

Tracklist se jinak ukládá až při otevření alba. Pomalu (MusicBrainz 1 req/s,
Deezer limit), jen alba bez `tracklistCount`.

    python -m app.tools.fill_tracklists
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
        ids = sorted(
            {
                rid
                for rid in session.exec(
                    select(Recording.release_id).join(MediaAsset, MediaAsset.recording_id == Recording.id)
                ).all()
                if rid
            }
        )
        todo = [rid for rid in ids if not ((session.get(Release, rid).external_refs or {}).get("tracklistCount"))]
    print(f"{len(todo)} alb bez tracklistu", flush=True)
    done = 0
    for rid in todo:
        try:
            with Session(engine) as session:
                svc = CatalogService(session, get_musicbrainz_client(), get_deezer_client())
                tracks = await svc.get_release_tracks(rid)
            done += 1 if tracks else 0
        except Exception as exc:  # noqa: BLE001
            print("chyba", rid, exc, flush=True)
        await asyncio.sleep(0.5)
    print(f"hotovo: {done}/{len(todo)}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
