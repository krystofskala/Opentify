"""Stažené soubory, jejichž délka výrazně nesedí na katalog (rozhovor, celé
album, jiná verze...), projede Shazamem (app/library/download_check.py) a
zapíše do přehledu kontroly stažených. Nic nemaže -- rozhodnutí je na
přehledu ("Stáhnout znovu" / "V pořádku").

    python -m app.tools.check_duration_mismatches
"""

from __future__ import annotations

import asyncio
from collections import Counter
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.library.download_check import _duration_off, check_recording
from app.models import MediaAsset, MediaAssetStatus, Recording

MEDIA_ROOT = Path("/data/media")


async def main() -> None:
    with Session(engine) as s:
        ids = [
            r.id
            for r, a in s.exec(
                select(Recording, MediaAsset)
                .join(MediaAsset, MediaAsset.recording_id == Recording.id)
                .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
            ).all()
            if a.storage_path
            and Path(a.storage_path).resolve().is_relative_to(MEDIA_ROOT)
            and a.waveform_duration_ms
            and _duration_off(r.duration_ms, a.waveform_duration_ms / 1000)
        ]
    print(f"kontroluji {len(ids)} souborů s nesedící délkou", flush=True)
    verdicts: Counter[str] = Counter()
    for rid in ids:
        entry = await check_recording(rid)
        if entry is None:
            continue
        v = entry.get("verdict") or "ok"
        verdicts[v] += 1
        if v != "ok":
            print(
                f"  {v}: {entry.get('artist')} – {entry.get('title')!r} "
                f"(čekáno {(entry.get('expectedMs') or 0) // 1000} s, je {(entry.get('actualMs') or 0) // 1000} s)"
                + (f" -> Shazam: {entry.get('gotArtist')} – {entry.get('gotTitle')}" if entry.get("gotTitle") else ""),
                flush=True,
            )
    print(f"hotovo: {dict(verdicts)}", flush=True)


if __name__ == "__main__":
    asyncio.run(main())
