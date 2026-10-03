"""Sdílená složka pro Soulseek s čitelnými jmény:
`/data/media/sdilene/Interpret/Album (rok)/01 - Název.flac`.

Soulseek hledá jen podle cesty a jména souboru -- naše `media/<uuid>.flac`
by nikdo nenašel. Sdílí se jen soubory ze Soulseeku (bezztrátové / původní
MP3), ne stažené z YouTube (překódované, komunita je nemá ráda).

Pevný odkaz (hardlink) = žádné místo navíc; kde ho souborový systém
nepovolí (Docker Desktop na Windows), kopie. Složka se drží v souladu
s databází: co už neplatí (smazané, nahrazené, přejmenované), zmizí.
"""

from __future__ import annotations

import errno
import logging
import os
import re
import shutil
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording, Release

logger = logging.getLogger("vault.share_view")

SHARE_ROOT = Path("/data/media/sdilene")
SHARED_PROVIDERS = {"slskd"}
_BAD = re.compile(r'[<>:"/\\|?*\x00-\x1f]')
_links_ok: bool | None = None


def _safe(name: str, limit: int = 80) -> str:
    name = _BAD.sub(" ", name or "").strip().rstrip(".")
    name = re.sub(r"\s+", " ", name)
    return name[:limit].strip() or "Neznámé"


def desired() -> dict[Path, Path]:
    """Cílová cesta ve sdílené složce -> soubor v `media`."""
    out: dict[Path, Path] = {}
    with Session(engine) as session:
        assets = session.exec(
            select(MediaAsset).where(
                MediaAsset.status == MediaAssetStatus.AVAILABLE,
                MediaAsset.source_provider.in_(SHARED_PROVIDERS),  # type: ignore[union-attr]
            )
        ).all()
        for asset in assets:
            if not asset.storage_path or not asset.storage_path.startswith("/data/media/"):
                continue
            rec = session.get(Recording, asset.recording_id)
            if rec is None:
                continue
            release = session.get(Release, rec.release_id) if rec.release_id else None
            artist = session.get(Artist, release.artist_id if release else rec.artist_id) if (release or rec.artist_id) else None
            year = (release.release_date or "")[:4] if release else ""
            album = _safe(f"{release.title} ({year})" if release and year else (release.title if release else "Singly"))
            number = f"{rec.track_number:02d} - " if rec.track_number else ""
            src = Path(asset.storage_path)
            name = _safe(f"{number}{rec.title}", 120) + src.suffix.lower()
            target = SHARE_ROOT / _safe(artist.name if artist else "Neznámý interpret") / album / name
            out.setdefault(target, src)
    return out


def _place(src: Path, dst: Path) -> None:
    global _links_ok
    dst.parent.mkdir(parents=True, exist_ok=True)
    tmp = dst.with_name(f".{dst.name}.tmp")
    if _links_ok is not False:
        try:
            if tmp.exists():
                tmp.unlink()
            os.link(src, tmp)
            os.replace(tmp, dst)
            _links_ok = True
            return
        except OSError as exc:
            if exc.errno not in (errno.EPERM, errno.EXDEV, errno.ENOTSUP, errno.EOPNOTSUPP):
                raise
            _links_ok = False
            logger.info("sdílená složka: pevné odkazy nejdou (%s) -- kopie", exc)
    shutil.copy2(src, tmp)
    os.replace(tmp, dst)


def _current(src: Path, dst: Path) -> bool:
    try:
        a, b = src.stat(), dst.stat()
    except OSError:
        return False
    if a.st_ino == b.st_ino and a.st_dev == b.st_dev:
        return True
    # Kopie: stejná velikost a ne starší než zdroj (po přetagování se obnoví).
    return a.st_size == b.st_size and b.st_mtime >= a.st_mtime


def sync() -> dict[str, int]:
    want = desired()
    placed = removed = 0
    for dst, src in want.items():
        if not src.is_file() or _current(src, dst):
            continue
        try:
            _place(src, dst)
            placed += 1
        except OSError as exc:
            logger.info("sdílená složka: %s: %s", dst.name, exc)
    if SHARE_ROOT.is_dir():
        for path in SHARE_ROOT.rglob("*"):
            if path.is_file() and path not in want:
                try:
                    path.unlink()
                    removed += 1
                except OSError:
                    pass
        for path in sorted((p for p in SHARE_ROOT.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
            try:
                if not any(path.iterdir()):
                    path.rmdir()
            except OSError:
                pass
    if placed or removed:
        logger.info("sdílená složka: přidáno/obnoveno %d, odebráno %d, celkem %d", placed, removed, len(want))
    return {"placed": placed, "removed": removed, "total": len(want)}
