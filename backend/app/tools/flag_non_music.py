"""Označí už uložená vydání, která jsou rozhovor / mluvené slovo
(app/catalog/non_music.py), a uklidí z nich stažené soubory.

Kandidáti: vydání s MBID, jehož skladby mají medián délky přes 5,5 min
nebo název jako "Interview". U nich se zeptá MusicBrainz na sekundární typ
(1 dotaz/s). Deezerová kopie (bez MBID) se označí, když má stejný
interpret stejnojmenné označené MB vydání, nebo podle názvu.

    python -m app.tools.flag_non_music [--dry-run]
"""

from __future__ import annotations

import asyncio
import statistics
import sys
from collections import defaultdict
from pathlib import Path

from sqlmodel import Session, select

from app.catalog.non_music import NON_MUSIC_TYPES, is_non_music_title, mentions_interview
from app.catalog.deezer_ingest import norm
from app.db import engine
from app.models import MediaAsset, MediaAssetStatus, Recording, Release

MEDIA_ROOT = Path("/data/media")


async def main(dry: bool) -> None:
    from app.catalog.musicbrainz import get_musicbrainz_client

    mb = get_musicbrainz_client()
    with Session(engine) as s:
        durations: dict[str, list[int]] = defaultdict(list)
        for rel_id, dur in s.exec(select(Recording.release_id, Recording.duration_ms)).all():
            if rel_id and dur:
                durations[rel_id].append(dur)
        releases = s.exec(select(Release)).all()
        candidates = [
            r for r in releases
            if r.mbid and not r.mbid.startswith("own:") and not (r.external_refs or {}).get("nonMusic")
            and (mentions_interview(r.title) or (len(durations[r.id]) >= 3 and statistics.median(durations[r.id]) > 330_000))
        ]
        print(f"kandidátů k ověření v MusicBrainz: {len(candidates)}", flush=True)
        flagged: list[Release] = []
        for r in candidates:
            try:
                rg = await mb.get_release_group(r.mbid)
            except Exception as exc:  # noqa: BLE001
                print(f"  MB chyba {r.title!r}: {exc}", flush=True)
                continue
            types = {t.lower() for t in rg.get("secondary-types") or []}
            if types & NON_MUSIC_TYPES:
                flagged.append(r)
        flagged += [r for r in releases if (r.external_refs or {}).get("nonMusic") and r not in flagged]
        flagged_keys = {(r.artist_id, norm(r.title)) for r in flagged}
        for r in releases:
            if r in flagged or r.mbid:
                continue
            if (r.artist_id, norm(r.title)) in flagged_keys or is_non_music_title(r.title):
                flagged.append(r)

        files = []
        for r in flagged:
            for rec in s.exec(select(Recording).where(Recording.release_id == r.id)).all():
                a = s.get(MediaAsset, rec.id)
                if a and a.status == MediaAssetStatus.AVAILABLE and a.storage_path:
                    files.append((rec, a))
        print(f"rozhovorových vydání: {len(flagged)}, stažených souborů z nich: {len(files)}")
        for r in flagged:
            print(f"  {r.title!r} ({'MB' if r.mbid else 'Deezer'}, artist {r.artist_id[:8]})")
        for rec, a in files:
            print(f"    soubor: {rec.title!r} {a.storage_path}")
        if dry:
            return
        for r in flagged:
            r.external_refs = {**(r.external_refs or {}), "nonMusic": True}
            s.add(r)
        for _rec, a in files:
            p = Path(a.storage_path)
            if p.resolve().is_relative_to(MEDIA_ROOT):
                p.unlink(missing_ok=True)  # jen naše stažené, nikdy vlastní hudba
            a.status = MediaAssetStatus.MISSING
            a.storage_path = None
            s.add(a)
        s.commit()
        print("hotovo")


if __name__ == "__main__":
    asyncio.run(main("--dry-run" in sys.argv))
