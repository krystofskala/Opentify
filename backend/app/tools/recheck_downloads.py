"""Přezkoumá stažené soubory stejnou kontrolou jako nová stažení
(app/library/verify_file.py) a jisté chyby opraví: soubor smaže, zdroj
i otisk zvuku zakáže a skladbu zařadí ke stažení znovu (s novými pravidly).

Jisté = otisk ukázky z Deezeru v souboru není, soubor je poškozený, nebo
obsahuje víc než skladbu (celé album / mix). Nesedí-li jen délka (může být
chybná v katalogu), jen se vypíše.

    python -m app.tools.recheck_downloads [--dry-run] [--limit N] [--from ID]
"""

from __future__ import annotations

import asyncio
import sys
from collections import Counter
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.library.verify_file import fingerprint_worth_keeping, signature, verify
from app.models import MediaAsset, MediaAssetStatus, Recording
from app.tools.verify_sample import target_for

MEDIA_ROOT = Path("/data/media")
SURE = ("jiná nahrávka", "obsahuje víc", "soubor je poškozený", "soubor nejde otevřít", "jen ", "soubor je podle tagů")


async def main(dry: bool, limit: int, start: str | None) -> None:
    from app.catalog.identity import is_own_id
    from app.provisioning_service import enqueue, get_or_create_job
    from app.auth import ADMIN_ID
    from app.worker import _reject_source

    with Session(engine) as s:
        rows = s.exec(
            select(Recording, MediaAsset)
            .join(MediaAsset, MediaAsset.recording_id == Recording.id)
            .where(
                MediaAsset.status == MediaAssetStatus.AVAILABLE,
                MediaAsset.source_provider.in_(["youtube", "slskd", "soundcloud"]),  # type: ignore[attr-defined]
            )
            .order_by(Recording.id)
        ).all()
        jobs = []
        for r, a in rows:
            if start and r.id < start:
                continue
            if not a.storage_path or not Path(a.storage_path).resolve().is_relative_to(MEDIA_ROOT):
                continue
            if is_own_id(r.mbid) or (r.external_refs or {}).get("youtubeId") or (r.external_refs or {}).get("soundcloudUrl"):
                continue  # vlastní hudba / přesný odkaz od uživatele
            jobs.append((r.id, Path(a.storage_path), target_for(s, r, a.source_provider or "")))
    jobs = jobs[:limit] if limit else jobs
    print(f"kontroluji {len(jobs)} souborů{' (nanečisto)' if dry else ''}", flush=True)
    stats: Counter[str] = Counter()
    for i, (rid, path, target) in enumerate(jobs, 1):
        try:
            v = await verify(path, target, full_decode=target.provider == "slskd", fix_ext=not dry)
        except Exception as exc:  # noqa: BLE001
            stats["chyba kontroly"] += 1
            print(f"  ! {rid}: {exc}", flush=True)
            continue
        if v.ok:
            stats[f"ok {v.confidence}"] += 1
            if not dry and v.path and v.path != path:
                with Session(engine) as s:
                    asset = s.get(MediaAsset, rid)
                    if asset is not None:
                        asset.storage_path = str(v.path)
                        asset.format = v.path.suffix.lstrip(".")
                        s.add(asset)
                        s.commit()
            continue
        sure = v.reason.startswith(SURE)
        stats["špatně (jisté)" if sure else "k posouzení"] += 1
        print(
            f"  {'OPRAVIT' if sure else 'POSOUDIT'} | {target.artist} – {target.title} | {v.reason} | {v.details.get('tag', '')} | {rid}",
            flush=True,
        )
        if dry or not sure:
            continue
        with Session(engine) as s:
            rec = s.get(Recording, rid)
            refs = dict(rec.external_refs or {}) if rec else {}
        key = refs.get("sourceKey")
        if not key and target.provider == "youtube" and refs.get("youtubeUrl"):
            key = f"youtube:{str(refs['youtubeUrl']).rsplit('=', 1)[-1]}"
        fp = await signature(v.path or path) if fingerprint_worth_keeping(v.reason) else None
        await asyncio.to_thread(_reject_source, rid, key, v.reason, fp)
        (v.path or path).unlink(missing_ok=True)
        with Session(engine) as s:
            asset = s.get(MediaAsset, rid)
            asset.status = MediaAssetStatus.MISSING
            asset.storage_path = None
            s.add(asset)
            s.commit()
            _asset, job, created = get_or_create_job(s, rid, ADMIN_ID, None)
        if job is not None and created:
            await enqueue(job)
        if i % 50 == 0:
            print(f"  ... {i}/{len(jobs)} {dict(stats)}", flush=True)
    print(f"hotovo: {dict(stats)}", flush=True)


if __name__ == "__main__":
    args = sys.argv
    asyncio.run(
        main(
            "--dry-run" in args,
            int(args[args.index("--limit") + 1]) if "--limit" in args else 0,
            args[args.index("--from") + 1] if "--from" in args else None,
        )
    )
