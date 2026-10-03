"""Vlastní hudba: soubor napojený na jinou skladbu (kompilace spárované podle
čísla stopy -- Tony Rice "Platinum collection": "Let It Ride" hrálo "Will You
Be Loving Another Man"). Najde skladbu stejného interpreta, jejíž název
odpovídá názvu souboru, a soubor přepojí na ni. Vždy nejdřív --dry-run.

    python -m app.tools.relink_local [--dry-run]
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

from sqlmodel import Session, select

from app.catalog.artwork import _normalize
from app.db import engine
from app.models import MediaAsset, MediaAssetStatus, Recording
from app.utils import utcnow

_PREFIX = re.compile(r"^(cd\s*\d+\s*[-_.]\s*)?\d{1,3}\s*[-_.)]\s*", re.I)


def file_title(path: str, artist: str) -> str:
    stem = Path(path).stem
    stem = _PREFIX.sub("", stem).strip()
    # "Interpret - Název"
    parts = re.split(r"\s+-\s+", stem, maxsplit=1)
    if len(parts) == 2 and _normalize(parts[0]) == _normalize(artist):
        stem = parts[1]
    return stem


def main(dry: bool) -> None:
    from app.models import Artist

    moves = []
    with Session(engine) as s:
        assets = s.exec(
            select(MediaAsset).where(
                MediaAsset.status == MediaAssetStatus.AVAILABLE,
                MediaAsset.source_provider.in_(("local", "musicbrainz-local")),  # type: ignore[union-attr]
            )
        ).all()
        for a in assets:
            rec = s.get(Recording, a.recording_id)
            if rec is None or not a.storage_path or not rec.artist_id:
                continue
            artist = s.get(Artist, rec.artist_id)
            ftitle = file_title(a.storage_path, artist.name if artist else "")
            if not ftitle or _normalize(ftitle) == _normalize(rec.title):
                continue
            if _normalize(rec.title) in _normalize(ftitle) or _normalize(ftitle) in _normalize(rec.title):
                continue  # "(Remastered)" apod. -- stejná skladba
            import difflib

            a_norm = _normalize(rec.title.replace("&", "and"))
            b_norm = _normalize(ftitle.replace("&", "and"))
            if a_norm == b_norm or difflib.SequenceMatcher(None, a_norm, b_norm).ratio() > 0.8:
                continue  # překlep / "&" vs "and" -- stejná píseň
            # Skladba stejného interpreta (ideálně stejného alba) s názvem souboru.
            cands = [
                r
                for r in s.exec(select(Recording).where(Recording.artist_id == rec.artist_id)).all()
                if _normalize(r.title) == _normalize(ftitle)
            ]
            cands.sort(key=lambda r: r.release_id != rec.release_id)
            target = next((r for r in cands if not _available(s, r.id)), None)
            # Jen jisté případy (existuje skladba přesně s názvem souboru).
            # Rozbité znaky v názvech souborů, překlepy a soubory pojmenované
            # číslem hrají správně -- ty se NEodpojují.
            if target is not None:
                moves.append((a, rec, ftitle, target))
        print(f"přeházených souborů: {len(moves)}")
        for a, rec, ftitle, target in moves:
            print(f"  „{rec.title}“ hraje „{ftitle}“ -> {'přepojit na ' + target.id[:8] if target else 'NENALEZENO (jen odpojit)'}")
        if dry:
            return
        for a, rec, _ftitle, target in moves:
            path, fields = a.storage_path, (a.checksum_sha256, a.filesize_bytes, a.format, a.bitrate_kbps, a.source_provider)
            # Původní skladba už ten soubor nehraje (dostane svůj správný, nebo se stáhne).
            a.status = MediaAssetStatus.MISSING
            a.storage_path = None
            s.add(a)
            if target is not None:
                t = s.get(MediaAsset, target.id) or MediaAsset(recording_id=target.id)
                t.storage_path = path
                t.checksum_sha256, t.filesize_bytes, t.format, t.bitrate_kbps, t.source_provider = fields
                t.status = MediaAssetStatus.AVAILABLE
                t.available_at = t.available_at or utcnow()
                t.loudness_gain_db = None
                t.waveform = None
                s.add(t)
        s.commit()
        print("hotovo")


def _available(s: Session, recording_id: str) -> bool:
    a = s.get(MediaAsset, recording_id)
    return a is not None and a.status == MediaAssetStatus.AVAILABLE


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
