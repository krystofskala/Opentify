"""Najde stažené skladby, jejichž soubor neodpovídá názvu nebo verzi
(dřív volnější pravidla: "Car Radio (Ned's Version)" se stáhla jako původní
Car Radio, "Trees (Ned's Version)" jako "Heathens / Trees (Livestream)"),
a stáhne je znovu s přísnými pravidly (původní zdroj jako odmítnutý).

    python -m app.tools.fix_wrong_versions [--dry-run] [--artist=<id>]
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

from sqlmodel import Session, select

from app.auth import ADMIN_ID
from app.db import engine
from app.models import MediaAsset, MediaAssetStatus, Recording
from app.download_match import match_label
from app.worker import MEDIA_ROOT


def _youtube_title(video_url: str) -> str | None:
    import yt_dlp

    from app.providers import _ytdlp_proxy_opts

    try:
        with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "skip_download": True, **_ytdlp_proxy_opts()}) as ydl:
            info = ydl.extract_info(video_url, download=False) or {}
        return info.get("title")
    except Exception:  # noqa: BLE001
        return None


async def main(dry_run: bool, artist_id: str | None) -> None:
    from app.provisioning_service import enqueue, get_or_create_job

    with Session(engine) as session:
        q = select(Recording, MediaAsset).join(MediaAsset, MediaAsset.recording_id == Recording.id).where(
            MediaAsset.status == MediaAssetStatus.AVAILABLE
        )
        if artist_id:
            q = q.where(Recording.artist_id == artist_id)
        from app.models import Release

        rows = []
        for rec, asset in session.exec(q).all():
            release = session.get(Release, rec.release_id) if rec.release_id else None
            rows.append(
                (rec.id, rec.title, dict(rec.external_refs or {}), asset.source_provider, asset.storage_path, release.title if release else None)
            )
    print(f"kontroluji {len(rows)} stažených skladeb", flush=True)
    bad = 0
    for rec_id, title, refs, provider, path, album in rows:
        if not path or not Path(path).resolve().is_relative_to(MEDIA_ROOT.resolve()):
            continue  # vlastní hudba
        key = refs.get("sourceKey") or ""
        if provider == "slskd" and key.startswith("slskd:"):
            filename = key.split("|", 1)[-1]
            # Název i verze v souboru, verze může být i ve složce alba.
            text = filename.replace("\\", " ")
            parts = filename.replace("\\", "/").split("/")
            ok = match_label(title, parts[-1], album=album, context=parts[-2] if len(parts) > 1 else "") is None
        elif provider == "youtube" and (refs.get("youtubeUrl") or key.startswith("youtube:")) and not refs.get("youtubeId"):
            url = refs.get("youtubeUrl") or f"https://www.youtube.com/watch?v={key.split(':', 1)[1]}"
            video_title = await asyncio.to_thread(_youtube_title, url)
            if video_title is None:
                continue
            ok = match_label(title, video_title, album=album) is None
            filename = video_title
        else:
            continue
        if ok:
            continue
        bad += 1
        print(f"  {title!r} <- {filename[-90:]!r}", flush=True)
        if dry_run:
            continue
        with Session(engine) as session:
            rec = session.get(Recording, rec_id)
            asset = session.get(MediaAsset, rec_id)
            if rec is None or asset is None:
                continue
            refs = dict(rec.external_refs or {})
            rejected = list(refs.get("rejectedSources") or [])
            if key and key not in rejected:
                rejected.append(key)
            refs["rejectedSources"] = rejected
            refs.pop("sourceKey", None)
            refs.pop("youtubeUrl", None)
            rec.external_refs = refs
            session.add(rec)
            if asset.storage_path:
                Path(asset.storage_path).unlink(missing_ok=True)
            asset.status = MediaAssetStatus.MISSING
            asset.storage_path = None
            session.add(asset)
            session.commit()
            _asset, job, created = get_or_create_job(session, rec_id, ADMIN_ID, None)
        if job is not None and created:
            await enqueue(job)
    print(f"hotovo, špatně staženo {bad}", flush=True)


if __name__ == "__main__":
    artist = next((a.split("=", 1)[1] for a in sys.argv if a.startswith("--artist=")), None)
    asyncio.run(main("--dry-run" in sys.argv, artist))
