"""Audiokniha z odkazu na YouTube (celé video = jedna kniha). Stejné
stahování jako u hudby (yt-dlp, přes Mullvad -- `_ytdlp_proxy_opts`),
jen celé video do jednoho m4a; kapitoly videa se uloží jako kapitoly
knihy (přehrávač je ukáže v Kapitolách).
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
from pathlib import Path
from typing import Any, Callable

logger = logging.getLogger(__name__)

_ID = re.compile(r"(?:youtube\.com/(?:watch\?(?:[^#\s]*&)?v=|shorts/|live/|embed/)|youtu\.be/)([A-Za-z0-9_-]{11})")
_INFO_TTL_S = 3600


def video_id(text: str | None) -> str | None:
    m = _ID.search(text or "")
    return m.group(1) if m else None


def watch_url(vid: str) -> str:
    return f"https://www.youtube.com/watch?v={vid}"


def _opts(**extra: Any) -> dict:
    from app.providers import _ytdlp_proxy_opts

    return {"quiet": True, "no_warnings": True, "noplaylist": True, "socket_timeout": 20, **_ytdlp_proxy_opts(), **extra}


def _extract(vid: str) -> dict:
    import yt_dlp

    with yt_dlp.YoutubeDL(_opts(skip_download=True)) as ydl:
        return ydl.extract_info(watch_url(vid), download=False) or {}


def summary(raw: dict) -> dict:
    duration = int(raw.get("duration") or 0)
    return {
        "id": raw.get("id"),
        "title": (raw.get("title") or "").strip(),
        "uploader": raw.get("uploader") or raw.get("channel"),
        "durationS": duration,
        # Odhad velikosti (m4a ~128 kb/s) -- pro limity stahování.
        "sizeBytes": duration * 16_000 if duration else None,
        "description": (raw.get("description") or "").strip()[:4000] or None,
        "thumbnail": raw.get("thumbnail"),
        "chapters": [
            {"title": str(c.get("title") or f"Kapitola {i + 1}"), "startMs": int(float(c.get("start_time") or 0) * 1000)}
            for i, c in enumerate(raw.get("chapters") or [])
        ],
    }


async def info(vid: str) -> dict | None:
    """Název, kanál, délka a kapitoly videa (hodina v mezipaměti)."""
    from app.redis_bus import get_redis

    r = get_redis()
    key = f"spoken:yt:info:v2:{vid}"
    cached = await r.get(key)
    if cached:
        return json.loads(cached)
    try:
        raw = await asyncio.to_thread(_extract, vid)
    except Exception as exc:  # noqa: BLE001 - neexistující / soukromé video
        logger.info("youtube info %s: %s", vid, exc)
        return None
    data = summary(raw)
    if not data["title"]:
        return None
    await r.set(key, json.dumps(data), ex=_INFO_TTL_S)
    return data


def fetch_thumbnail(url: str, dest: Path) -> bool:
    """Náhled videa jako obal knihy -- stáhne server (přes Mullvad), telefon
    na YouTube nechodí."""
    import os

    import httpx

    proxy = os.environ.get("YTDLP_PROXY") or None
    try:
        with httpx.Client(proxy=proxy, timeout=20, follow_redirects=True) as c:
            resp = c.get(url)
        if resp.status_code != 200 or not resp.content:
            return False
        dest.write_bytes(resp.content)
        return True
    except httpx.HTTPError:
        return False


def download(vid: str, dest: Path, on_progress: Callable[[float], None]) -> Path:
    """Celé video jako m4a do `dest` (synchronní, volá se ve vlákně)."""
    import yt_dlp

    dest.mkdir(parents=True, exist_ok=True)

    def hook(d: dict) -> None:
        if d.get("status") != "downloading":
            return
        total = d.get("total_bytes") or d.get("total_bytes_estimate")
        if total:
            on_progress(min(0.99, float(d.get("downloaded_bytes") or 0) / float(total)))

    opts = _opts(
        outtmpl=str(dest / "%(id)s.%(ext)s"),
        format="bestaudio[ext=m4a]/bestaudio",
        continuedl=False,
        retries=3,
        progress_hooks=[hook],
    )
    with yt_dlp.YoutubeDL(opts) as ydl:
        ydl.extract_info(watch_url(vid), download=True)
    files = [p for p in dest.iterdir() if p.is_file() and p.stem == vid and not p.name.endswith(".part")]
    if not files:
        raise RuntimeError("yt-dlp nevytvořil soubor")
    return to_mp3_if_long(files[0])


# Delší než 20 min -> MP3: m4a z YouTube má u 2,5 h knihy 1,5 MB obsahu na
# začátku souboru, iPhone ho musí načíst celý, než začne hrát, a na pomalé
# cestě to nestihl (8. 10.: Hobit nešel pustit). MP3 hraje hned a skáče se
# v něm kamkoli (CBR).
LONG_S = 20 * 60


def _duration_s(path: Path) -> float | None:
    import subprocess

    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", str(path)],
            capture_output=True, text=True, timeout=60,
        ).stdout.strip()
        return float(out) if out else None
    except (OSError, ValueError, subprocess.SubprocessError):
        return None


def to_mp3_if_long(path: Path) -> Path:
    """Dlouhý zvuk jiný než MP3 převede na MP3 128 kb/s (původní smaže);
    krátký nebo při chybě vrátí původní."""
    import subprocess

    if path.suffix.lower() == ".mp3":
        return path
    duration = _duration_s(path)
    if duration is None or duration < LONG_S:
        return path
    out = path.with_suffix(".mp3")
    tmp = path.with_suffix(".mp3.part")
    try:
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin", "-y", "-i", str(path),
             "-vn", "-map_metadata", "0", "-c:a", "libmp3lame", "-b:a", "128k", "-f", "mp3", str(tmp)],
            check=True, timeout=3600,
        )
        tmp.replace(out)
        path.unlink(missing_ok=True)
        return out
    except (OSError, subprocess.SubprocessError) as exc:
        logger.warning("převod na MP3 selhal (%s): %s", path.name, exc)
        tmp.unlink(missing_ok=True)
        return path
