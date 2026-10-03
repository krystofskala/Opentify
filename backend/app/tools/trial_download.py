"""Zkušební stažení celou cestou workeru (hledání -> stažení -> kontrola)
do /tmp/trial -- knihovna, databáze ani zakázané zdroje se NEMĚNÍ.

    python -m app.tools.trial_download ID [ID ...]
"""

from __future__ import annotations

import asyncio
import shutil
import sys
import time
from pathlib import Path

from app import worker
from app.redis_bus import get_redis

TRIAL = Path("/tmp/trial")


async def _noop(*_a, **_k) -> None:
    return None


async def main(ids: list[str]) -> None:
    TRIAL.mkdir(parents=True, exist_ok=True)
    worker.MEDIA_ROOT = TRIAL  # type: ignore[attr-defined]
    worker._reject_source = lambda rid, key, reason: print(f"      zamítnuto {key}: {reason}", flush=True)  # type: ignore[assignment]
    worker._spawn_upgrade = lambda *a, **k: None  # type: ignore[assignment]
    worker._store_duration = lambda *a, **k: None  # type: ignore[assignment]
    r = get_redis()
    for rid in ids:
        ctx = await asyncio.to_thread(_ctx, rid)
        if ctx is None:
            print(f"{rid}: neznámá nahrávka")
            continue
        track = worker.TrackMetadata(
            recording_id=rid,
            title=ctx["recording_title"],
            artist_name=ctx.get("artist_name"),
            mbid=ctx.get("recording_mbid"),
            duration_ms=ctx.get("recording_duration_ms"),
            rejected_sources=tuple(ctx.get("rejected_sources") or ()),
            album_title=ctx.get("album_title"),
            track_number=ctx.get("track_number"),
            isrc=ctx.get("isrc"),
        )
        print(f"== {track.artist_name} – {track.title} [{(track.duration_ms or 0) // 1000}s]", flush=True)
        if not track.duration_ms:
            from app.library.verify_file import resolve_duration

            ms, dz = await resolve_duration(worker._verify_target(track, ctx, ""))
            print(f"      délka dohledána: {ms} (deezer {dz})", flush=True)
            if ms:
                import dataclasses

                track = dataclasses.replace(track, duration_ms=ms)
                ctx["deezer_id"] = ctx.get("deezer_id") or dz
        started = time.monotonic()
        try:
            res = await worker._acquire_verified(r, f"trial-{rid}", track, ctx, False, _noop, _noop)
            print(f"   OK {res.source_provider} {res.format} {res.bitrate_kbps} kbps  {res.source_key}  ({time.monotonic() - started:.0f} s)", flush=True)
            res.path.unlink(missing_ok=True)
        except Exception as exc:  # noqa: BLE001
            print(f"   NEMÁME: {str(exc)[:240]}  ({time.monotonic() - started:.0f} s)", flush=True)
    shutil.rmtree(TRIAL, ignore_errors=True)


def _ctx(rid: str) -> dict | None:
    from sqlmodel import Session

    from app.db import engine
    from app.models import Artist, Recording

    with Session(engine) as s:
        rec = s.get(Recording, rid)
        if rec is None:
            return None
        artist = s.get(Artist, rec.artist_id) if rec.artist_id else None
        refs = rec.external_refs or {}
        # Současný (špatný) soubor je známý -- v pokusu ho zakázat, jako by ho
        # uživatel nahlásil, ať je vidět, co nová cesta vybere místo něj.
        rejected = list(refs.get("rejectedSources") or [])
        if refs.get("sourceKey"):
            rejected.append(refs["sourceKey"])
        return {
            "recording_title": rec.title,
            "artist_name": artist.name if artist else None,
            "recording_mbid": rec.mbid,
            "recording_duration_ms": rec.duration_ms,
            "rejected_sources": rejected,
            "album_title": worker._album_title(s, rec),
            "track_number": rec.track_number,
            "isrc": rec.isrc,
            "deezer_id": rec.deezer_id,
        }


if __name__ == "__main__":
    asyncio.run(main(sys.argv[1:]))
