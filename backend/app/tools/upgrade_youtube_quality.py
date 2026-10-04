"""Skladby stažené jen z YouTube (~128-160 kbps) zkusí nahradit lepší verzí
ze Soulseeku (FLAC / 320 kbps) -- přes VPN, stejným přísným hledáním jako
každé stahování. Nový soubor se stáhne vedle, projde stejnou kontrolou
(délka, otisk ukázky, AcoustID) a teprve pak se prohodí; když se nic
lepšího nenajde, zůstane původní soubor. Pomalu, po jedné skladbě (v noci).

Vynechá: přesné video/odkaz od uživatele (youtubeId), SoundCloud, vlastní
importy a skladby, které se už zkoušely posledních 30 dní.

    python -m app.tools.upgrade_youtube_quality [--dry-run] [--limit N]
"""

from __future__ import annotations

import asyncio
import dataclasses
import sys
from datetime import date, timedelta
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording

MEDIA_ROOT = Path("/data/media")
RETRY_AFTER = timedelta(days=30)


def _candidates(limit: int) -> list[str]:
    today = date.today()
    out: list[str] = []
    with Session(engine) as s:
        rows = s.exec(
            select(Recording, MediaAsset)
            .join(MediaAsset, MediaAsset.recording_id == Recording.id)
            .where(MediaAsset.status == MediaAssetStatus.AVAILABLE, MediaAsset.source_provider == "youtube")
            .order_by(MediaAsset.available_at.desc())  # type: ignore[union-attr]
        ).all()
        for r, _a in rows:
            refs = r.external_refs or {}
            if refs.get("youtubeId") or refs.get("soundcloudUrl") or (r.mbid or "").startswith("own:"):
                continue
            tried = refs.get("qualityUpgradeTried")
            if tried and today - date.fromisoformat(tried) < RETRY_AFTER:
                continue
            out.append(r.id)
            if len(out) >= limit:
                break
    return out


def _mark_tried(recording_id: str) -> None:
    with Session(engine) as s:
        rec = s.get(Recording, recording_id)
        if rec is not None:
            rec.external_refs = {**(rec.external_refs or {}), "qualityUpgradeTried": date.today().isoformat()}
            s.add(rec)
            s.commit()


async def upgrade_one(recording_id: str, dry: bool) -> str:
    from app.library.verify_file import verify
    from app.providers import SlskdProvider, TrackMetadata
    from app.worker import _album_title, _apply_upgrade, _target_from_db, _version_hint

    with Session(engine) as s:
        r = s.get(Recording, recording_id)
        a = s.get(MediaAsset, recording_id)
        if r is None or a is None or a.status != MediaAssetStatus.AVAILABLE or a.source_provider != "youtube":
            return "přeskočeno (mezitím změněno)"
        artist = s.get(Artist, r.artist_id) if r.artist_id else None
        refs = r.external_refs or {}
        track = TrackMetadata(
            recording_id=r.id,
            title=r.title,
            artist_name=artist.name if artist else None,
            mbid=r.mbid,
            duration_ms=r.duration_ms,
            rejected_sources=tuple(refs.get("rejectedSources") or ()),
            album_title=_album_title(s, r),
            track_number=r.track_number,
            isrc=r.isrc,
            version_hint=_version_hint(s, r),
        )
        current = a.storage_path
    if not track.duration_ms:
        if not dry:
            _mark_tried(recording_id)
        return "bez délky -- nejde bezpečně ověřit"
    slskd = SlskdProvider()
    try:
        candidate = await slskd.resolve(track)
    except Exception as exc:  # noqa: BLE001
        return f"hledání selhalo ({str(exc)[:80]})"
    if candidate is None:
        if not dry:
            _mark_tried(recording_id)
        return "na Soulseeku nic lepšího"
    if dry:
        return f"našlo by: {candidate.source_ref[:90]}"
    stem = MEDIA_ROOT / f"{recording_id}_hq"

    async def _noop(*_a) -> None:
        return None

    try:
        result = await slskd.fetch(track, candidate, stem, _noop, _noop)
    except Exception as exc:  # noqa: BLE001
        _mark_tried(recording_id)
        return f"stažení selhalo ({str(exc)[:80]})"
    target = await asyncio.to_thread(_target_from_db, recording_id, result.source_provider)
    verdict = await verify(result.path, target, full_decode=True)
    if not verdict.ok:
        (verdict.path or result.path).unlink(missing_ok=True)
        _mark_tried(recording_id)
        return f"soubor neprošel kontrolou ({verdict.reason})"
    result = dataclasses.replace(result, path=verdict.path or result.path)
    applied = await asyncio.to_thread(
        _apply_upgrade,
        recording_id,
        str(result.path),
        current,
        result.source_provider,
        result.format,
        result.bitrate_kbps,
        result.source_key,
    )
    _mark_tried(recording_id)
    if not applied:
        result.path.unlink(missing_ok=True)
        return "neprohozeno (soubor se mezitím změnil)"
    from app.worker import _schedule_loudness

    _schedule_loudness(recording_id)
    return f"nahrazeno ({result.format}, {result.bitrate_kbps or '?'} kbps)"


async def run(limit: int = 30, dry: bool = False) -> int:
    ids = await asyncio.to_thread(_candidates, limit)
    print(f"kandidátů: {len(ids)}", flush=True)
    done = 0
    for rid in ids:
        msg = await upgrade_one(rid, dry)
        done += msg.startswith("nahrazeno")
        print(f"  {rid[:8]}: {msg}", flush=True)
    print(f"hotovo: {done}/{len(ids)} nahrazeno", flush=True)
    return done


if __name__ == "__main__":
    args = sys.argv
    asyncio.run(run(int(args[args.index("--limit") + 1]) if "--limit" in args else 30, "--dry-run" in args))
