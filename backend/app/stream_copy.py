"""Menší kopie hi-res souborů pro přehrávání.

FLAC 24 bit / 192 kHz má i 5 Mbit/s (Heart of Gold 114 MB na 3 minuty) a
přes mobil se nestíhal stahovat -- iPhone se zasekával každých pár sekund
(živě 16. 10.). Soubory nad `THRESHOLD_KBPS` se proto pro stream jednou
převedou na FLAC 16 bit / 44,1 kHz (pořád bezztrátově v CD kvalitě, ~1 Mbit/s)
do `MEDIA_ROOT/stream-cache/`. Originál zůstává nedotčený; když se změní
(upgrade souboru), kopie se vyrobí znovu.
"""

from __future__ import annotations

import asyncio
import logging
import os
from pathlib import Path

from app.provisioning_service import MEDIA_ROOT

log = logging.getLogger(__name__)

THRESHOLD_KBPS = 2000
CACHE_DIR = MEDIA_ROOT / "stream-cache"
_CONVERT_TIMEOUT_S = 60.0
_LOSSLESS = {".flac", ".wav"}

_locks: dict[str, asyncio.Lock] = {}


def needs_copy(path: Path, bitrate_kbps: int | None) -> bool:
    return path.suffix.lower() in _LOSSLESS and (bitrate_kbps or 0) > THRESHOLD_KBPS


def _fresh(copy: Path, original: Path) -> bool:
    try:
        return copy.stat().st_mtime >= original.stat().st_mtime and copy.stat().st_size > 0
    except OSError:
        return False


async def _convert(original: Path, copy: Path) -> bool:
    tmp = copy.with_name(copy.name + ".tmp.flac")
    await asyncio.to_thread(CACHE_DIR.mkdir, parents=True, exist_ok=True)
    cmd = [
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y",
        "-i", str(original), "-map", "0:a:0", "-map_metadata", "0",
        "-ar", "44100", "-sample_fmt", "s16", "-c:a", "flac", str(tmp),
    ]
    proc = await asyncio.create_subprocess_exec(
        *cmd, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.PIPE
    )
    try:
        _, err = await asyncio.wait_for(proc.communicate(), _CONVERT_TIMEOUT_S)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        log.warning("stream-copy: převod %s trval přes %.0f s", original.name, _CONVERT_TIMEOUT_S)
        await asyncio.to_thread(tmp.unlink, missing_ok=True)
        return False
    if proc.returncode != 0:
        log.warning("stream-copy: převod %s selhal: %s", original.name, (err or b"").decode(errors="replace")[:300])
        await asyncio.to_thread(tmp.unlink, missing_ok=True)
        return False
    await asyncio.to_thread(os.replace, tmp, copy)
    log.info("stream-copy: %s převedeno na 44,1 kHz / 16 bit", original.name)
    return True


async def path_for_stream(recording_id: str, original: Path, bitrate_kbps: int | None) -> Path:
    """Cesta, kterou poslat klientovi: menší kopie u hi-res, jinak originál.
    Při chybě převodu vždy originál -- stream nikdy neselže kvůli kopii."""
    if not needs_copy(original, bitrate_kbps):
        return original
    copy = CACHE_DIR / f"{recording_id}.flac"
    if await asyncio.to_thread(_fresh, copy, original):
        return copy
    lock = _locks.setdefault(recording_id, asyncio.Lock())
    async with lock:
        if await asyncio.to_thread(_fresh, copy, original):
            return copy
        try:
            ok = await _convert(original, copy)
        except Exception:  # noqa: BLE001 -- ffmpeg chybí apod.: hrát originál
            log.exception("stream-copy: převod %s spadl", original.name)
            ok = False
    _locks.pop(recording_id, None)
    return copy if ok else original
