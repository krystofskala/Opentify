"""Smaže otisky zamítnutých souborů tam, kde zamítnutí nebylo kvůli JINÉ
nahrávce (celé album / dlouhé video se správnou písní uvnitř, poškozený či
prázdný soubor) -- takový otisk by odmítal i správná stažení. Skladby, které
kvůli tomu skončily "nemáme", zařadí ke stažení znovu.

    python -m app.tools.clear_bad_fingerprints LOG [--dry-run]

LOG = výpis recheck_downloads (řádky "OPRAVIT | ... | důvod | ... | id").
"""

from __future__ import annotations

import asyncio
import sys

from sqlmodel import Session

from app.db import engine
from app.library.verify_file import fingerprint_worth_keeping
from app.models import MediaAsset, MediaAssetStatus, Recording


async def main(log: str, dry: bool) -> None:
    from app.auth import ADMIN_ID
    from app.provisioning_service import enqueue, get_or_create_job

    ids = []
    for line in open(log, encoding="utf-8"):
        if not line.startswith("  OPRAVIT"):
            continue
        parts = [p.strip() for p in line.split("|")]
        reason, rid = parts[2], parts[-1]
        if not fingerprint_worth_keeping(reason):
            ids.append((rid, reason))
    print(f"skladeb s vadným otiskem: {len(ids)}")
    for rid, reason in ids:
        with Session(engine) as s:
            rec = s.get(Recording, rid)
            asset = s.get(MediaAsset, rid)
            if rec is None:
                continue
            refs = dict(rec.external_refs or {})
            had = len(refs.get("rejectedFingerprints") or [])
            print(f"  {rec.title} | {reason} | otisků {had} | {asset.status if asset else None}")
            if dry:
                continue
            refs.pop("rejectedFingerprints", None)
            rec.external_refs = refs
            s.add(rec)
            s.commit()
            if asset is not None and asset.status != MediaAssetStatus.AVAILABLE:
                _a, job, created = get_or_create_job(s, rid, ADMIN_ID, None)
            else:
                job, created = None, False
        if job is not None and created:
            await enqueue(job)
    print("hotovo")


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1], "--dry-run" in sys.argv))
