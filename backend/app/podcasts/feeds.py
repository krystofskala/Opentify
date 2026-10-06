"""Hledání podcastů, čtení RSS a bezpečné stahování z cizích adres.

Adresy kanálů a epizod přicházejí zvenku (katalog, RSS) -- server je stahuje
přes Mullvad proxy, která vidí i vnitřní Docker síť. Proto se před každým
požadavkem (i po přesměrování) ověří, že cíl je veřejná adresa, ne
localhost / soukromá síť (jinak by šlo přes podcast sáhnout na vnitřní
služby).
"""

from __future__ import annotations

import asyncio
import html
import ipaddress
import logging
import os
import re
import socket
from datetime import datetime, timezone
from email.utils import parsedate_to_datetime
from urllib.parse import urljoin, urlparse
from xml.etree import ElementTree as ET

import httpx

logger = logging.getLogger(__name__)

_UA = "Opentify-Podcasts/1.0"
_ITUNES = "{http://www.itunes.com/dtds/podcast-1.0.dtd}"
MAX_FEED_BYTES = 15 * 1024 * 1024
MAX_EPISODES = 300


def proxy() -> str | None:
    return os.environ.get("PODCAST_PROXY", "http://gluetun:8888") or None


class UnsafeUrl(ValueError):
    pass


def _public_host(host: str) -> bool:
    try:
        infos = socket.getaddrinfo(host, None)
    except socket.gaierror:
        return False
    for info in infos:
        ip = ipaddress.ip_address(info[4][0])
        if not ip.is_global or ip.is_multicast:
            return False
    return bool(infos)


async def check_url(url: str) -> str:
    parsed = urlparse(url)
    if parsed.scheme not in ("http", "https") or not parsed.hostname or parsed.username or parsed.password:
        raise UnsafeUrl("nepovolená adresa")
    if parsed.port not in (None, 80, 443):
        raise UnsafeUrl("nepovolený port")
    if not await asyncio.to_thread(_public_host, parsed.hostname):
        raise UnsafeUrl("adresa nevede do veřejného internetu")
    return url


async def safe_get(client: httpx.AsyncClient, url: str, *, headers: dict | None = None, stream: bool = False):
    """GET s ručně ověřeným každým přesměrováním (max 5)."""
    for _ in range(6):
        await check_url(url)
        req = client.build_request("GET", url, headers=headers)
        resp = await client.send(req, stream=stream, follow_redirects=False)
        if resp.status_code in (301, 302, 303, 307, 308) and resp.headers.get("location"):
            nxt = urljoin(url, resp.headers["location"])
            await resp.aclose()
            url = nxt
            continue
        return resp
    raise UnsafeUrl("příliš mnoho přesměrování")


# --- Hledání ------------------------------------------------------------------


async def search(query: str, limit: int = 25) -> list[dict]:
    async with httpx.AsyncClient(proxy=proxy(), timeout=15, headers={"User-Agent": _UA}) as c:
        resp = await c.get(
            "https://itunes.apple.com/search",
            params={"term": query, "media": "podcast", "country": "cz", "limit": limit},
        )
        resp.raise_for_status()
    out = []
    for r in resp.json().get("results", []):
        feed = r.get("feedUrl")
        if not feed:
            continue  # bez RSS (exkluzivní pro Spotify apod.) nejde přehrát
        out.append(
            {
                "itunesId": str(r.get("collectionId") or ""),
                "title": r.get("collectionName") or r.get("trackName") or "",
                "author": r.get("artistName"),
                "artworkUrl": r.get("artworkUrl600") or r.get("artworkUrl100"),
                "feedUrl": feed,
                "episodeCount": r.get("trackCount"),
                "genre": r.get("primaryGenreName"),
            }
        )
    return out


# --- RSS --------------------------------------------------------------------------


def _text(el, path: str) -> str | None:
    found = el.find(path)
    if found is None or found.text is None:
        return None
    text = found.text.strip()
    return text or None


def _duration_ms(raw: str | None) -> int | None:
    if not raw:
        return None
    raw = raw.strip()
    try:
        if ":" in raw:
            parts = [float(p) for p in raw.split(":")]
            secs = 0.0
            for p in parts:
                secs = secs * 60 + p
            return int(secs * 1000)
        return int(float(raw) * 1000)
    except ValueError:
        return None


def _date(raw: str | None) -> datetime | None:
    if not raw:
        return None
    try:
        d = parsedate_to_datetime(raw)
    except (TypeError, ValueError):
        return None
    return d if d.tzinfo else d.replace(tzinfo=timezone.utc)


_TAGS = re.compile(r"<[^>]+>")


def _plain(raw: str | None, limit: int = 2000) -> str | None:
    if not raw:
        return None
    text = html.unescape(_TAGS.sub(" ", raw))
    text = re.sub(r"\s+", " ", text).strip()
    return text[:limit] or None


def parse_feed(xml: bytes) -> dict:
    """{title, author, description, artworkUrl, episodes: [...]}, nejnovější první."""
    root = ET.fromstring(xml)
    channel = root.find("channel")
    if channel is None:
        raise ValueError("není to RSS podcastu")
    image = channel.find(f"{_ITUNES}image")
    artwork = image.get("href") if image is not None else _text(channel, "image/url")
    episodes = []
    for item in channel.findall("item"):
        enclosure = item.find("enclosure")
        url = enclosure.get("url") if enclosure is not None else None
        if not url:
            continue
        guid = _text(item, "guid") or url
        ep_image = item.find(f"{_ITUNES}image")
        episodes.append(
            {
                "guid": guid[:500],
                "title": (_text(item, "title") or "Bez názvu")[:500],
                "description": _plain(_text(item, f"{_ITUNES}summary") or _text(item, "description")),
                "publishedAt": _date(_text(item, "pubDate")),
                "durationMs": _duration_ms(_text(item, f"{_ITUNES}duration")),
                "audioUrl": url.strip(),
                "artworkUrl": ep_image.get("href") if ep_image is not None else None,
            }
        )
    episodes.sort(key=lambda e: e["publishedAt"] or datetime.min.replace(tzinfo=timezone.utc), reverse=True)
    return {
        "title": (_text(channel, "title") or "Podcast")[:500],
        "author": _text(channel, f"{_ITUNES}author"),
        "description": _plain(_text(channel, f"{_ITUNES}summary") or _text(channel, "description")),
        "artworkUrl": artwork,
        "episodes": episodes[:MAX_EPISODES],
    }


async def fetch_feed(url: str) -> dict:
    async with httpx.AsyncClient(proxy=proxy(), timeout=30, headers={"User-Agent": _UA}) as c:
        resp = await safe_get(c, url, stream=True)
        try:
            resp.raise_for_status()
            data = bytearray()
            async for chunk in resp.aiter_bytes():
                data.extend(chunk)
                if len(data) > MAX_FEED_BYTES:
                    raise ValueError("RSS je příliš velké")
        finally:
            await resp.aclose()
    if is_youtube_feed(url):
        return await _youtube_feed(bytes(data), url)
    return await asyncio.to_thread(parse_feed, bytes(data))


# --- YouTube kanál jako podcast ------------------------------------------------
#
# Pořady, které nemají RSS (jen YouTube; Spotify ho mimo svou appku nepustí).
# Kanál: YouTube RSS (data, pořadí) + seznam videí přes yt-dlp (délky, bez
# Shorts). Zvuk: yt-dlp najde adresu audia a server ji přeposílá jako
# u běžné epizody -- stejný yt-dlp a proxy jako stahování hudby z YouTube.

_YT_FEED = "https://www.youtube.com/feeds/videos.xml?channel_id="
_YT_WATCH = "https://www.youtube.com/watch?v="
_ATOM = "{http://www.w3.org/2005/Atom}"
_YT = "{http://www.youtube.com/xml/schemas/2015}"
_MEDIA = "{http://search.yahoo.com/mrss/}"


def youtube_proxy() -> str | None:
    return os.environ.get("YTDLP_PROXY") or None


def is_youtube_feed(url: str) -> bool:
    return url.startswith(_YT_FEED)


def youtube_video_id(audio_url: str) -> str | None:
    return audio_url[len(_YT_WATCH):] if audio_url.startswith(_YT_WATCH) else None


_YT_LINK = re.compile(r"(?:https?://)?(?:www\.|m\.)?youtube\.com/(@[\w.\-]+|channel/UC[\w-]{22}|c/[\w.\-]+)", re.I)


def youtube_channel_link(query: str) -> str | None:
    """Odkaz na kanál / @jméno z vyhledávacího pole, jinak None."""
    q = query.strip()
    m = _YT_LINK.search(q)
    if m:
        return f"https://www.youtube.com/{m.group(1)}"
    if re.fullmatch(r"@[\w.\-]{3,}", q):
        return f"https://www.youtube.com/{q}"
    return None


async def resolve_youtube_channel(link: str) -> dict | None:
    """Výsledek ve tvaru hledání (`feedUrl` = RSS kanálu), nebo None."""
    async with httpx.AsyncClient(
        proxy=youtube_proxy(), timeout=20, follow_redirects=True,
        headers={"User-Agent": "Mozilla/5.0", "Accept-Language": "cs"}, cookies={"SOCS": "CAI"},
    ) as c:
        page = (await c.get(link)).text
    m = re.search(r'<link rel="canonical" href="https://www\.youtube\.com/channel/(UC[\w-]{22})"', page) or re.search(
        r'"channelId":"(UC[\w-]{22})"', page
    )
    if not m:
        return None
    title = re.search(r'<meta property="og:title" content="([^"]+)"', page)
    image = re.search(r'<meta property="og:image" content="([^"]+)"', page)
    return {
        "itunesId": None,
        "title": html.unescape(title.group(1)) if title else "YouTube kanál",
        "author": "YouTube",
        "artworkUrl": html.unescape(image.group(1)) if image else None,
        "feedUrl": _YT_FEED + m.group(1),
    }


async def _yt_dlp(*args: str, timeout: float = 90) -> str:
    cmd = ["yt-dlp", "--no-warnings", *args]
    if youtube_proxy():
        cmd[1:1] = ["--proxy", youtube_proxy()]
    proc = await asyncio.create_subprocess_exec(*cmd, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise
    if proc.returncode != 0:
        raise RuntimeError(f"yt-dlp: {err.decode(errors='replace')[-200:]}")
    return out.decode()


async def youtube_audio_url(video_id: str) -> str:
    out = await _yt_dlp("-f", "bestaudio[ext=m4a]/bestaudio", "-g", _YT_WATCH + video_id)
    return out.strip().splitlines()[-1]


async def _youtube_feed(xml: bytes, url: str) -> dict:
    import json

    root = ET.fromstring(xml)
    channel_id = url[len(_YT_FEED):]
    try:
        listing = json.loads(await _yt_dlp(
            "--flat-playlist", "-J", "--playlist-end", "60", f"https://www.youtube.com/channel/{channel_id}/videos"
        ))
    except Exception as e:  # noqa: BLE001 -- bez seznamu aspoň RSS (i s klipy)
        logger.warning("youtube %s: seznam videí nešel načíst (%s)", channel_id, e)
        listing = {}
    durations = {e["id"]: e.get("duration") for e in listing.get("entries") or [] if e.get("id")}
    episodes = []
    for entry in root.findall(f"{_ATOM}entry"):
        vid = _text(entry, f"{_YT}videoId")
        if not vid or (durations and vid not in durations):
            continue  # Shorts / klipy nejsou mezi videi kanálu
        group = entry.find(f"{_MEDIA}group")
        thumb = group.find(f"{_MEDIA}thumbnail") if group is not None else None
        published = _text(entry, f"{_ATOM}published")
        dur = durations.get(vid)
        episodes.append({
            "guid": f"yt:{vid}",
            "title": (_text(entry, f"{_ATOM}title") or "Bez názvu")[:500],
            "description": _plain(_text(group, f"{_MEDIA}description") if group is not None else None),
            "publishedAt": datetime.fromisoformat(published) if published else None,
            "durationMs": int(dur * 1000) if dur else None,
            "audioUrl": _YT_WATCH + vid,
            "artworkUrl": thumb.get("url") if thumb is not None else None,
        })
    thumbs = listing.get("thumbnails") or []
    avatar = next((t.get("url") for t in reversed(thumbs) if "avatar" in (t.get("id") or "") or t.get("width") == t.get("height")), None)
    return {
        "title": (listing.get("channel") or _text(root, f"{_ATOM}title") or "YouTube kanál")[:500],
        "author": "YouTube",
        "description": _plain(listing.get("description")),
        "artworkUrl": avatar,
        "episodes": episodes,
    }
