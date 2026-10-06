"""SkTorrent (sktorrent.eu): české a slovenské audioknihy v kategorii 24
"Mluvené slovo". Hledání je veřejné (bez přihlášení), stažení .torrent
souboru chce účet (`SKTORRENT_USERNAME` / `SKTORRENT_PASSWORD` v .env).

Vše přes Mullvad proxy (gluetun), ne z domácí IP. Stránky nemají API --
čte se HTML výpisu; id výsledku je rovnou infohash torrentu.
"""

from __future__ import annotations

import html
import logging
import os
import re
from dataclasses import asdict, dataclass

import httpx

logger = logging.getLogger(__name__)

BASE = "https://sktorrent.eu/torrent"
SPOKEN_CATEGORY = "24"
_UA = "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36"


def _proxy() -> str | None:
    return os.environ.get("SKTORRENT_PROXY", "http://gluetun:8888") or None


@dataclass
class Release:
    infohash: str
    title: str
    size_bytes: int | None
    seeders: int
    leechers: int
    cover_url: str | None
    added: str | None

    def to_json(self) -> dict:
        d = asdict(self)
        return {
            "infohash": d["infohash"],
            "title": d["title"],
            "sizeBytes": d["size_bytes"],
            "seeders": d["seeders"],
            "leechers": d["leechers"],
            "coverUrl": d["cover_url"],
            "added": d["added"],
        }


_UNITS = {"B": 1, "KB": 1024, "MB": 1024**2, "GB": 1024**3, "TB": 1024**4}

# Jedna buňka výsledku: kategorie, odkaz na detail (id = infohash), název,
# velikost, datum, seedeři, stahující.
_ITEM = re.compile(
    r"category=(?P<cat>\d+)[^>]*>.*?"
    r'details\.php\?name=[^&"]*&id=(?P<hash>[0-9a-f]{40})"\s+title="(?P<title>[^"]*)".*?'
    r"Velkost\s+(?P<size>[\d.,]+)\s*(?P<unit>[KMGT]?B)\s*\|\s*Pridany\s+(?P<added>[\d/]+).*?"
    r"Odosielaju\s*:\s*(?P<seed>\d+).*?Stahuju\s*:\s*(?P<leech>\d+)",
    re.S,
)
_PREFIX = re.compile(r"^Stiahni si .*?(Mluvené slovo|Mluvene slovo)\s+", re.I)


def parse_results(page: str) -> list[Release]:
    out: list[Release] = []
    seen: set[str] = set()
    for m in _ITEM.finditer(page):
        if m.group("cat") != SPOKEN_CATEGORY or m.group("hash") in seen:
            continue
        seen.add(m.group("hash"))
        title = _PREFIX.sub("", html.unescape(m.group("title"))).strip()
        try:
            size = int(float(m.group("size").replace(",", ".")) * _UNITS[m.group("unit").upper()])
        except (ValueError, KeyError):
            size = None
        out.append(
            Release(
                infohash=m.group("hash"),
                title=title,
                size_bytes=size,
                seeders=int(m.group("seed")),
                leechers=int(m.group("leech")),
                cover_url=f"https://cdn.sktorrent.eu/obrazky/{m.group('hash')}.jpg",
                added=m.group("added"),
            )
        )
    return out


async def search(query: str) -> list[Release]:
    """Audioknihy podle dotazu, nejvíc seedů první (bez seedů na konec)."""
    async with httpx.AsyncClient(proxy=_proxy(), timeout=20, follow_redirects=True, headers={"User-Agent": _UA}) as c:
        resp = await c.get(f"{BASE}/torrents_v2.php", params={"search": query, "category": SPOKEN_CATEGORY, "active": "0"})
        resp.raise_for_status()
    return sorted(parse_results(resp.text), key=lambda r: (r.seeders == 0, -r.seeders))


def credentials() -> tuple[str, str] | None:
    user = os.environ.get("SKTORRENT_USERNAME", "").strip()
    password = os.environ.get("SKTORRENT_PASSWORD", "")
    return (user, password) if user and password else None


class NotConfigured(RuntimeError):
    pass


async def download_torrent(infohash: str) -> bytes:
    """Přihlásí se a stáhne .torrent soubor (obsahuje osobní passkey -- nikam
    se neukládá kromě torrent klienta)."""
    creds = credentials()
    if creds is None:
        raise NotConfigured("chybí přihlášení na SkTorrent (SKTORRENT_USERNAME / SKTORRENT_PASSWORD v .env)")
    async with httpx.AsyncClient(proxy=_proxy(), timeout=30, follow_redirects=True, headers={"User-Agent": _UA}) as c:
        login = await c.post(f"{BASE}/login.php", data={"uid": creds[0], "pwd": creds[1]})
        login.raise_for_status()
        detail = await c.get(f"{BASE}/details.php", params={"id": infohash})
        detail.raise_for_status()
        if 'name="pwd"' in detail.text and "logout" not in detail.text.lower():
            raise PermissionError("přihlášení na SkTorrent se nepovedlo (špatné jméno / heslo?)")
        link = re.search(r'href="?([^"\s>]*download\.php\?[^"\s>]+)', detail.text)
        if link is None:
            raise LookupError("na stránce torrentu chybí odkaz ke stažení")
        url = html.unescape(link.group(1))
        if not url.startswith("http"):
            url = f"{BASE}/{url.lstrip('/')}"
        resp = await c.get(url)
        resp.raise_for_status()
        if not resp.content.startswith(b"d"):  # bencode slovník
            raise ValueError("SkTorrent nevrátil .torrent soubor")
        return resp.content
