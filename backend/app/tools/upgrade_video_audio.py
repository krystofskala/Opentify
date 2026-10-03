"""Soubory z videoklipu nahradí oficiální audio stopou (YouTube "Provided to
YouTube by ..." / "- Topic"). Videoklip mívá intro a outro navíc, takže
synchronizované texty nesedí (přání majitele 2026-10-03).

Kandidáti: soubory označené `videoSource` (nová stažení) a starší soubory
z YouTube, které jsou o víc než max(4 s, 3 %) delší než skladba. Nové audio
se stáhne vedle, projde stejnou kontrolou jako každé stažení a teprve pak se
prohodí -- když se nic lepšího nenajde, zůstane původní soubor.

    python -m app.tools.upgrade_video_audio [--dry-run] [--limit N]
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording

MEDIA_ROOT = Path("/data/media")


def _candidates(limit: int) -> list[str]:
    out: list[tuple[int, str]] = []
    with Session(engine) as s:
        for r, a in s.exec(
            select(Recording, MediaAsset)
            .join(MediaAsset, MediaAsset.recording_id == Recording.id)
            .where(MediaAsset.status == MediaAssetStatus.AVAILABLE, MediaAsset.source_provider == "youtube")
        ).all():
            refs = r.external_refs or {}
            if refs.get("youtubeId") or refs.get("videoAudioTried"):
                continue  # přesné video od uživatele / už zkoušeno
            padded = bool(
                r.duration_ms and a.waveform_duration_ms
                and a.waveform_duration_ms - r.duration_ms > max(4000, r.duration_ms * 0.03)
            )
            if refs.get("videoSource") or padded:
                out.append((0 if refs.get("videoSource") else 1, r.id))
    out.sort()
    return [rid for _p, rid in out[:limit]]


def _mark_tried(recording_id: str) -> None:
    from app.utils import utcnow

    with Session(engine) as s:
        rec = s.get(Recording, recording_id)
        if rec is not None:
            rec.external_refs = {**(rec.external_refs or {}), "videoAudioTried": utcnow().date().isoformat()}
            s.add(rec)
            s.commit()


async def upgrade_one(recording_id: str, dry: bool) -> str:
    import dataclasses

    from app.library.verify_file import verify
    from app.providers import TrackMetadata, YoutubeProvider, youtube_pick
    from app.worker import _album_title, _apply_upgrade, _target_from_db, _version_hint

    with Session(engine) as s:
        r = s.get(Recording, recording_id)
        a = s.get(MediaAsset, recording_id)
        artist = s.get(Artist, r.artist_id) if r.artist_id else None
        refs = r.external_refs or {}
        track = TrackMetadata(
            recording_id=r.id,
            title=r.title,
            artist_name=artist.name if artist else None,
            mbid=r.mbid,
            duration_ms=r.duration_ms,
            rejected_sources=tuple(refs.get("rejectedSources") or ()) + ((refs["sourceKey"],) if refs.get("sourceKey") else ()),
            album_title=_album_title(s, r),
            isrc=r.isrc,
            version_hint=_version_hint(s, r),
            official_audio_only=True,
        )
        current = a.storage_path
    try:
        picks = await asyncio.to_thread(youtube_pick, track, track.search_query)
    except Exception as exc:  # noqa: BLE001
        if not dry:
            _mark_tried(recording_id)
        return f"oficiální audio nenalezeno ({str(exc)[:80]})"
    if dry:
        return f"našlo by: {picks[0].get('title')} | {picks[0].get('channel')} | {picks[0].get('duration')} s"
    yt = YoutubeProvider()
    candidate = await yt.resolve(track)
    stem = MEDIA_ROOT / f"{recording_id}_audio"

    async def _noop(*_a) -> None:
        return None

    try:
        result = await yt.fetch(track, candidate, stem, _noop, _noop)
    except Exception as exc:  # noqa: BLE001
        _mark_tried(recording_id)
        return f"stažení selhalo ({str(exc)[:80]})"
    target = await asyncio.to_thread(_target_from_db, recording_id, "youtube")
    verdict = await verify(result.path, target)
    if not verdict.ok:
        (verdict.path or result.path).unlink(missing_ok=True)
        _mark_tried(recording_id)
        return f"audio neprošlo kontrolou ({verdict.reason})"
    result = dataclasses.replace(result, path=verdict.path or result.path)
    applied = await asyncio.to_thread(
        _apply_upgrade, recording_id, str(result.path), current, "youtube", result.format, result.bitrate_kbps, result.source_key
    )
    if not applied:
        return "neprohozeno (soubor se mezitím změnil)"
    from app.worker import _remember_source_key, _schedule_loudness

    await asyncio.to_thread(_remember_source_key, recording_id, result.source_key, 0)
    _schedule_loudness(recording_id)
    return "nahrazeno oficiálním audiem"


async def run(limit: int = 40, dry: bool = False) -> int:
    ids = await asyncio.to_thread(_candidates, limit)
    done = 0
    for rid in ids:
        msg = await upgrade_one(rid, dry)
        done += msg.startswith("nahrazeno")
        print(f"  {rid[:8]}: {msg}", flush=True)
    print(f"hotovo: {done}/{len(ids)} nahrazeno", flush=True)
    return done


if __name__ == "__main__":
    args = sys.argv
    asyncio.run(run(int(args[args.index("--limit") + 1]) if "--limit" in args else 40, "--dry-run" in args))
