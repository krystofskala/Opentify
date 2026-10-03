"""Úklid meziskladu Soulseeku (`SLSKD_DOWNLOADS_DIR`).

slskd stahuje do složky pojmenované podle složky odesílatele; hotový soubor
se po ověření PŘESUNE do `media` (podle id skladby) a prázdná složka zůstane.
Zůstávají i soubory, které nikdo nepoužívá: stejný soubor stažený dvakrát
naráz (slskd přidá `_<ticks>`), zamítnuté po kontrole, zrušená stahování.

Smaže se jen to, na co nic v databázi neodkazuje (stahovaný soubor, ze
kterého se zrovna přehrává, má `storage_path` sem) a co je dost staré, aby
to nebylo rozpracované stahování.
"""

from __future__ import annotations

import logging
import os
import time
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.models import MediaAsset

logger = logging.getLogger("vault.slskd_janitor")

FILE_MIN_AGE_S = 6 * 3600
DIR_MIN_AGE_S = 3600


def clean(root: Path, *, now: float | None = None) -> dict[str, int]:
    if not root.is_dir():
        return {"files": 0, "bytes": 0, "dirs": 0}
    now = now or time.time()
    prefix = str(root)
    with Session(engine) as session:
        referenced = {
            p for p in session.exec(select(MediaAsset.storage_path).where(MediaAsset.storage_path.startswith(prefix))).all()  # type: ignore[union-attr]
            if p
        }
    files = size = dirs = 0
    for path in root.rglob("*"):
        try:
            if not path.is_file() or str(path) in referenced:
                continue
            st = path.stat()
            if now - st.st_mtime < FILE_MIN_AGE_S:
                continue
            path.unlink()
            files += 1
            size += st.st_size
        except OSError:
            continue
    # Nejhlubší složky první, ať se smaže i rodič, který tím zůstal prázdný.
    for path in sorted((p for p in root.rglob("*") if p.is_dir()), key=lambda p: len(p.parts), reverse=True):
        try:
            if now - path.stat().st_mtime < DIR_MIN_AGE_S or any(path.iterdir()):
                continue
            path.rmdir()
            dirs += 1
        except OSError:
            continue
    if files or dirs:
        logger.info("mezisklad slskd: smazáno %d souborů (%.1f MB) a %d prázdných složek", files, size / 1e6, dirs)
    return {"files": files, "bytes": size, "dirs": dirs}


def downloads_root() -> Path:
    return Path(os.environ.get("SLSKD_DOWNLOADS_DIR", "/data/slskd-downloads"))


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    print(clean(downloads_root()))
