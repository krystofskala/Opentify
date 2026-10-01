"""Limity nahrávaných souborů -- celý soubor se jinak načte do paměti
(obří upload / "ZIP bomba" by shodila API na počítači s málo RAM)."""

from __future__ import annotations

import zipfile

from fastapi import HTTPException, UploadFile

MAX_ZIP_ENTRY = 200 * 1024 * 1024  # jeden soubor v ZIPu po rozbalení
MAX_ZIP_TOTAL = 1024 * 1024 * 1024  # všechny dohromady


async def read_limited(file: UploadFile, max_bytes: int, what: str = "Soubor") -> bytes:
    chunks: list[bytes] = []
    total = 0
    while chunk := await file.read(1024 * 1024):
        total += len(chunk)
        if total > max_bytes:
            raise HTTPException(status_code=413, detail=f"{what} je moc velký (max {max_bytes // (1024 * 1024)} MB).")
        chunks.append(chunk)
    return b"".join(chunks)


def check_zip(zf: zipfile.ZipFile) -> None:
    """Rozbalené velikosti z hlavičky ZIPu -- odmítnout dřív, než se čte."""
    total = 0
    for info in zf.infolist():
        if info.file_size > MAX_ZIP_ENTRY:
            raise zipfile.BadZipFile(f"soubor {info.filename} je po rozbalení moc velký")
        total += info.file_size
    if total > MAX_ZIP_TOTAL:
        raise zipfile.BadZipFile("ZIP je po rozbalení moc velký")
