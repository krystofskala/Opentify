"""Noční záloha databáze na jiný disk (houbař, `/data/media/_zalohy/db`).

Kopie za běhu přes SQLite backup API (konzistentní i během zápisů), pak
gzip. Drží posledních `KEEP_DAILY` dní a k tomu první zálohu každého měsíce
(`KEEP_MONTHLY` měsíců). Složka není ve sdílení Soulseeku (sdílí se jen
`sdilene/` a lokální hudba).

Ručně: `python -m app.maintenance.db_backup`."""
from __future__ import annotations

import gzip
import logging
import os
import shutil
import sqlite3
import time
from datetime import date
from pathlib import Path

from app.db import DATABASE_URL

logger = logging.getLogger(__name__)

BACKUP_DIR = Path(os.environ.get("DB_BACKUP_DIR", "/data/media/_zalohy/db"))
KEEP_DAILY = 14
KEEP_MONTHLY = 6
# Novější záloha než tohle = dnes už hotovo (worker to zkouší každých 15 s).
MIN_AGE_S = 20 * 3600


def _db_path() -> Path:
    return Path(DATABASE_URL.removeprefix("sqlite:///"))


def _backups() -> list[Path]:
    return sorted(BACKUP_DIR.glob("vault-*.db.gz"))


def due() -> bool:
    files = _backups()
    return not files or time.time() - files[-1].stat().st_mtime > MIN_AGE_S


def backup() -> Path:
    BACKUP_DIR.mkdir(parents=True, exist_ok=True)
    target = BACKUP_DIR / f"vault-{date.today().isoformat()}.db.gz"
    # Mezikopie vedle databáze (Linuxový disk): SQLite na disku připojeném
    # z Windows (houbař) neumí sdílenou paměť WAL a záloha tam visela.
    tmp_db = _db_path().parent / ".vault-backup.tmp.db"
    tmp_gz = BACKUP_DIR / ".vault-backup.tmp.gz"
    for leftover in (tmp_db, BACKUP_DIR / ".vault-backup.tmp.db", BACKUP_DIR / ".vault-backup.tmp.db-shm",
                     BACKUP_DIR / ".vault-backup.tmp.db-wal"):
        leftover.unlink(missing_ok=True)
    src = sqlite3.connect(f"file:{_db_path()}?mode=ro", uri=True)
    dst = sqlite3.connect(tmp_db)
    try:
        src.backup(dst, pages=4096, sleep=0.05)  # po kouscích, ať neblokuje zápisy
        dst.execute("PRAGMA journal_mode=DELETE")  # záloha = jeden samostatný soubor
        ok = dst.execute("PRAGMA quick_check").fetchone()[0]
        if ok != "ok":
            raise RuntimeError(f"záloha neprošla kontrolou: {ok}")
    finally:
        dst.close()
        src.close()
    with tmp_db.open("rb") as fin, gzip.open(tmp_gz, "wb", compresslevel=6) as fout:
        shutil.copyfileobj(fin, fout, length=1 << 20)
    tmp_db.unlink()
    os.replace(tmp_gz, target)  # hotová záloha se objeví až celá
    prune()
    logger.info("záloha databáze: %s (%.1f MB)", target.name, target.stat().st_size / 1e6)
    return target


def prune() -> None:
    files = _backups()
    keep = set(files[-KEEP_DAILY:])
    months: dict[str, Path] = {}
    for f in files:  # vzestupně -> první záloha v měsíci
        months.setdefault(f.name[6:13], f)
    keep |= set(sorted(months.values())[-KEEP_MONTHLY:])
    for f in files:
        if f not in keep:
            f.unlink()


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    print(backup())
