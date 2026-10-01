"""Znovu stáhne skladby interpreta v co nejlepší kvalitě -- album po albu.

Každé album nejdřív jako celá složka ze Soulseeku (`plan_album`), pak se
znovu stáhnou skladby, které nejsou FLAC ze Soulseeku (YouTube, MP3...).
Další album až po doběhnutí předchozího (ne stovky stahování naráz).
Vlastní hudba (mimo MEDIA_ROOT) ani alba z YouTube / ruční se nemění.

    python -m app.tools.redownload_artist "twenty one pilots"
"""

from __future__ import annotations

import asyncio
import logging
import sys
from pathlib import Path

from sqlmodel import Session, select

from app.auth import ADMIN_ID
from app.db import engine
from app.library.album_download import plan_album
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording, Release
from app.provisioning_service import enqueue, get_or_create_job
from app.routes.library import MEDIA_ROOT, _remove_from_library

logging.basicConfig(level=logging.INFO, format="%(asctime)s %(message)s")
log = logging.getLogger("redownload")


def _good(asset: MediaAsset | None) -> bool:
    return bool(
        asset
        and asset.storage_path
        and asset.source_provider == "slskd"
        and asset.storage_path.lower().endswith(".flac")
    )


async def main(name: str) -> None:
    with Session(engine) as session:
        artists = [a.id for a in session.exec(select(Artist).where(Artist.name == name)).all()]
        rows = session.exec(select(Recording).where(Recording.artist_id.in_(artists))).all()  # type: ignore[attr-defined]
        releases: dict[str, list[str]] = {}
        for rec in rows:
            asset = session.get(MediaAsset, rec.id)
            if rec.release_id and asset and asset.storage_path:
                releases.setdefault(rec.release_id, []).append(rec.id)
    log.info("%s: %d alb se staženými skladbami", name, len(releases))
    for release_id, rec_ids in releases.items():
        with Session(engine) as session:
            release = session.get(Release, release_id)
            if release is None or (release.external_refs or {}).get("source") in ("youtube", "manual"):
                continue
            # Jen studiová alba -- ne singly, EP, kompilace, živáky.
            if (release.release_type or "").lower() != "album" or "live" in release.title.lower():
                continue
            title = release.title
        plan = await plan_album(release_id)
        todo: list[str] = []
        with Session(engine) as session:
            for rid in rec_ids:
                asset = session.get(MediaAsset, rid)
                if _good(asset):
                    continue
                rec = session.get(Recording, rid)
                if rec is not None and (rec.external_refs or {}).get("youtubeId"):
                    continue  # skladba z odkazu na YouTube -- jen to video
                if not Path(asset.storage_path).resolve().is_relative_to(MEDIA_ROOT.resolve()):
                    continue  # vlastní hudba
                _remove_from_library(session, rid)
                _a, job, created = get_or_create_job(session, rid, ADMIN_ID, "redownload")
                if job is not None and created:
                    await enqueue(job)
                todo.append(rid)
        log.info("%s: složka %s, znovu %d z %d", title, plan.get("folder") or "-", len(todo), len(rec_ids))
        # Počkat, až album doběhne (max 30 min), pak další.
        for _ in range(180):
            if not todo:
                break
            await asyncio.sleep(10)
            with Session(engine) as session:
                todo = [
                    rid
                    for rid in todo
                    if (a := session.get(MediaAsset, rid)) is not None
                    and a.status not in (MediaAssetStatus.AVAILABLE, MediaAssetStatus.FAILED)
                ]
        with Session(engine) as session:
            flac = sum(1 for rid in rec_ids if _good(session.get(MediaAsset, rid)))
        log.info("%s: hotovo, FLAC ze Soulseeku %d/%d", title, flac, len(rec_ids))


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1] if len(sys.argv) > 1 else "twenty one pilots"))
