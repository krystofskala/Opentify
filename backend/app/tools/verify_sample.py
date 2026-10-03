"""Zkouška `verify_file.verify` na stažených souborech bez zásahu do nich.

    python -m app.tools.verify_sample ID [ID ...]      # konkrétní nahrávky
    python -m app.tools.verify_sample --random N        # náhodné stažené
"""

from __future__ import annotations

import asyncio
import random
import sys
import time
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.library.verify_file import Target, verify
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording


def target_for(s: Session, r: Recording, provider: str) -> Target:
    from app.worker import _album_title

    artist = s.get(Artist, r.artist_id) if r.artist_id else None
    return Target(
        recording_id=r.id,
        title=r.title,
        artist=artist.name if artist else None,
        album=_album_title(s, r),
        expected_ms=r.duration_ms,
        deezer_id=r.deezer_id,
        isrc=r.isrc,
        mbid=r.mbid,
        provider=provider,
    )


async def main(ids: list[str], n_random: int) -> None:
    with Session(engine) as s:
        if n_random:
            rows = s.exec(
                select(MediaAsset.recording_id).where(
                    MediaAsset.status == MediaAssetStatus.AVAILABLE,
                    MediaAsset.source_provider.in_(["youtube", "slskd", "soundcloud"]),  # type: ignore[attr-defined]
                )
            ).all()
            ids = ids + random.Random(11).sample(list(rows), min(n_random, len(rows)))
        jobs = []
        for rid in ids:
            r = s.get(Recording, rid)
            a = s.get(MediaAsset, rid)
            if r is None or a is None or not a.storage_path:
                print(f"{rid}: nic ke kontrole")
                continue
            jobs.append((rid, Path(a.storage_path), target_for(s, r, a.source_provider or "")))
    for rid, path, target in jobs:
        started = time.monotonic()
        v = await verify(path, target, full_decode=target.provider == "slskd", fix_ext=False)
        took = time.monotonic() - started
        print(
            f"{'OK ' if v.ok else 'ZAMÍTNUTO'} | {target.artist} – {target.title} | {v.reason} | {v.confidence} | "
            f"ber={v.details.get('ber')} | {took:.1f}s | {rid[:8]}",
            flush=True,
        )


if __name__ == "__main__":
    args = sys.argv[1:]
    n = 0
    if "--random" in args:
        i = args.index("--random")
        n = int(args[i + 1])
        args = args[:i] + args[i + 2 :]
    asyncio.run(main(args, n))
