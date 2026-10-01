"""Import z odkazu na Apple Music (playlist, album, skladba) -- bez účtu.

- Skladba (`/album/<slug>/<id>?i=<track>` nebo `/song/<slug>/<id>`) a album:
  veřejné iTunes Lookup API (`itunes.apple.com/lookup`).
- Playlist (`/playlist/<slug>/pl.<id>`): veřejná stránka playlistu nese JSON
  `serialized-server-data` se skladbami (název, interpret, délka).

Soukromí stejně jako u Spotify (app/library/spotify_link.py): VÝHRADNĚ přes
Mullvad VPN proxy, Apple domácí IP nevidí; obal stahuje server.
"""

from __future__ import annotations

import json
import re
from typing import Any

import httpx

from app.library.spotify_import import TrackRow

_URL = re.compile(
    r"music\.apple\.com/(?P<cc>[a-z]{2})/(?P<kind>album|playlist|song)/(?:[^/?#]+/)?(?P<id>pl\.[A-Za-z0-9]+|\d+)"
)
_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Safari/537.36"


def is_apple_music_url(text: str) -> bool:
    return "music.apple.com/" in (text or "")


def parse_apple_url(text: str) -> tuple[str, str, str] | None:
    """(druh, id, země). Album s `?i=` je skladba."""
    m = _URL.search(text or "")
    if not m:
        return None
    kind, ident, cc = m.group("kind"), m.group("id"), m.group("cc")
    track = re.search(r"[?&]i=(\d+)", text)
    if kind == "album" and track:
        return "track", track.group(1), cc
    if kind == "song":
        return "track", ident, cc
    return kind, ident, cc


def _big_artwork(url: str | None) -> str | None:
    # artworkUrl100 -> 600x600 (Apple CDN umí libovolnou velikost v názvu).
    return re.sub(r"/\d+x\d+bb\.", "/600x600bb.", url) if url else None


async def fetch_apple_link(
    text: str, proxy: str
) -> tuple[str, str, str, str | None, list[TrackRow], bytes | None]:
    """-> (druh, id, název, autor, skladby, obal) -- stejný tvar jako Spotify."""
    parsed = parse_apple_url(text)
    if parsed is None:
        raise ValueError("Tohle nevypadá jako odkaz na Apple Music playlist, album nebo skladbu.")
    kind, ident, cc = parsed
    async with httpx.AsyncClient(proxy=proxy, timeout=30, headers={"User-Agent": _UA}, follow_redirects=True) as client:
        cover_url: str | None = None
        if kind in ("track", "album"):
            params: dict[str, Any] = {"id": ident, "country": cc}
            if kind == "album":
                params["entity"] = "song"
            resp = await client.get("https://itunes.apple.com/lookup", params=params)
            resp.raise_for_status()
            results = resp.json().get("results") or []
            tracks = [r for r in results if r.get("wrapperType") == "track"]
            if not tracks:
                raise ValueError("Apple Music tenhle obsah nenašel.")
            if kind == "track":
                t = tracks[0]
                name, owner = t.get("trackName") or "", t.get("artistName")
                rows: list[TrackRow] = [(t.get("artistName") or "", name, t.get("collectionName"), t.get("trackTimeMillis"))]
                cover_url = _big_artwork(t.get("artworkUrl100"))
            else:
                coll = next((r for r in results if r.get("wrapperType") == "collection"), tracks[0])
                name, owner = coll.get("collectionName") or "", coll.get("artistName")
                rows = [
                    (t.get("artistName") or "", t.get("trackName") or "", name, t.get("trackTimeMillis"))
                    for t in sorted(tracks, key=lambda t: (t.get("discNumber") or 1, t.get("trackNumber") or 0))
                ]
                cover_url = _big_artwork(coll.get("artworkUrl100"))
        else:
            # Jazyk z odkazu (`?l=cs`) -- jinak Apple vrátí anglický název.
            lang = re.search(r"[?&]l=([A-Za-z-]+)", text)
            resp = await client.get(
                f"https://music.apple.com/{cc}/playlist/playlist/{ident}",
                params={"l": lang.group(1)} if lang else {"l": cc},
            )
            if resp.status_code == 404:
                raise ValueError("Apple Music tenhle playlist nenašel -- možná je soukromý.")
            resp.raise_for_status()
            name, owner, rows, cover_url = _parse_playlist_page(resp.text)
        cover: bytes | None = None
        if cover_url:
            try:
                img = await client.get(cover_url)
                if img.status_code == 200 and len(img.content) < 5 * 1024 * 1024:
                    cover = img.content
            except httpx.HTTPError:
                cover = None  # obal je jen bonus
    rows = [r for r in rows if r[0] and r[1]]
    return kind, ident, name or "Apple Music", owner, rows, cover


def _parse_playlist_page(html: str) -> tuple[str, str | None, list[TrackRow], str | None]:
    name, owner, cover = "", None, None
    ld = re.search(r'<script id=schema:music-playlist type="application/ld\+json">(.*?)</script>', html, re.S)
    if ld:
        try:
            meta = json.loads(ld.group(1))
            name = meta.get("name") or ""
            author = meta.get("author")
            owner = author.get("name") if isinstance(author, dict) else None
            image = meta.get("image")
            cover = image if isinstance(image, str) else None
        except json.JSONDecodeError:
            pass
    m = re.search(r'<script[^>]*id="serialized-server-data"[^>]*>(.*?)</script>', html, re.S)
    if not m:
        raise ValueError("Apple Music vrátil nečekanou stránku, zkus to později.")
    rows: list[TrackRow] = []
    seen: set[int] = set()

    def walk(node: Any) -> None:
        if isinstance(node, dict):
            if "title" in node and "artistName" in node and "duration" in node and id(node) not in seen:
                seen.add(id(node))
                rows.append((node.get("artistName") or "", node.get("title") or "", None, node.get("duration")))
                return
            for value in node.values():
                walk(value)
        elif isinstance(node, list):
            for value in node:
                walk(value)

    walk(json.loads(m.group(1)))
    return name, owner, rows, cover
