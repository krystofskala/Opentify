"""Úklid "cizích" skladeb u alb: nahrávky z jiných edic (bonusový / živý
disk deluxe edice, regionální bonusy), které v DB visí u alba, ale v jeho
kanonickém tracklistu nejsou (viz `_canonical_edition` v catalog/service.py).
Tracklist alba je už neukazuje, ale strašily jinde (knihovna, hledání).

Cíl je najít co nejvíc hudby, ne míň (přání vlastníka). Proto se NEMAŽE
nic unikátního -- jiné pásky koncertů, bonusy jiných edic, živé verze
zůstávají (najdou se dál). Sloučí se jen DVOJNÍCI: kopie bez MBID (Deezer,
sken) se stejným názvem jako skladba kanonického tracklistu = táž skladba.
Sloučení převede všechno, co na dvojníka odkazuje (dedupe.merge_recording).
Jen alba z MusicBrainz (jiná nemají kanonickou edici).

    python -m app.tools.clean_stray_recordings [--dry-run]"""
from __future__ import annotations

import asyncio
import sys
from collections import Counter

from sqlalchemy import func
from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.musicbrainz import get_musicbrainz_client
from app.catalog.service import CatalogService
from app.db import engine
from app.maintenance import dedupe
from app.models import ProvisioningJobStatus, Recording, Release

_FINAL = (ProvisioningJobStatus.FAILED, ProvisioningJobStatus.SUCCEEDED)


def _candidates() -> list[str]:
    """Alba z MB, která mají v DB víc skladeb než jejich tracklist."""
    with Session(engine) as session:
        rows = session.exec(
            select(Release.id, Release.external_refs, func.count(Recording.id))
            .join(Recording, Recording.release_id == Release.id)
            .where(Release.mbid.is_not(None), ~Release.mbid.startswith("own:"))  # type: ignore[union-attr]
            .group_by(Release.id)
        ).all()
    out = []
    for rid, refs, n in rows:
        refs = refs or {}
        if refs.get("source") in ("youtube", "soundcloud", "manual"):
            continue
        known = refs.get("tracklistCount")
        if known is None or n > known:
            out.append(rid)
    return out


async def main(dry: bool) -> None:
    todo = _candidates()
    print(f"alb k prověření: {len(todo)}", flush=True)
    stats: Counter = Counter()
    for n, rid in enumerate(todo, 1):
        with Session(engine) as session:
            try:
                tracks = await CatalogService(session, get_musicbrainz_client(), get_deezer_client()).get_release_tracks(rid)
                session.commit()
            except Exception as exc:  # noqa: BLE001
                stats["chyba tracklistu"] += 1
                print(f"  {rid}: {exc}", flush=True)
                continue
            release = session.get(Release, rid)
            # Tracklist musí být z MB a úplný, jinak nic nemazat.
            if not tracks or release is None or release.mbid is None:
                stats["bez tracklistu"] += 1
                continue
            keep = {t.id for t in tracks}
            canonical = {dedupe.track_key(r.title): r for r in session.exec(select(Recording).where(Recording.id.in_(keep))).all()}  # type: ignore[attr-defined]
            for rec in session.exec(select(Recording).where(Recording.release_id == rid)).all():
                if rec.id in keep:
                    continue
                twin = canonical.get(dedupe.track_key(rec.title))
                if rec.mbid or twin is None:
                    stats["unikátní (zůstávají)"] += 1
                    continue
                if rec.isrc and twin.isrc and rec.isrc != twin.isrc:
                    stats["jiné ISRC (zůstávají)"] += 1
                    continue
                stats["sloučeno s originálem"] += 1
                if not dry:
                    dedupe.merge_recording(session, rec, twin)
            if not dry:
                session.commit()
        if n % 100 == 0:
            print(f"  {n}/{len(todo)} {dict(stats)}", flush=True)
    print(("nanečisto: " if dry else "hotovo: ") + str(dict(stats)), flush=True)


if __name__ == "__main__":
    asyncio.run(main("--dry-run" in sys.argv))
