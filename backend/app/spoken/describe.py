"""Popis knihy (detail audioknihy) z Google Books -- jen jako záloha a jen
při jisté shodě: stejný název, autor a české vydání. Ověřeno 7. 10.: volné
hledání "Zaklínač Sapkowski" vrátí knihu o počítačové hře; radši nic než
cizí popis.

Klíč `GOOGLE_BOOKS_API_KEY` v .env (bez něj se nic nehledá).
"""

from __future__ import annotations

import logging
import os
import re
from pathlib import Path
from typing import Any

import httpx

from app.catalog.cache import cached_json
from app.spoken.people import fold

logger = logging.getLogger(__name__)

URL = "https://www.googleapis.com/books/v1/volumes"
TTL_S = 30 * 24 * 3600
_http = httpx.AsyncClient(timeout=10.0)


def _key() -> str | None:
    return os.environ.get("GOOGLE_BOOKS_API_KEY") or None


def _clean_title(title: str) -> str:
    """"55-Heir to the Empire (2010)" -> "heir to the empire"; podtitul pryč."""
    title = re.sub(r"^\d+\s*[-.]\s*", "", title)
    title = re.sub(r"[\[(].*?[\])]", "", title)
    return fold(re.split(r"\s[-–:]\s|:", title)[0])


def _surname(author: str) -> str:
    """"Jirotka, Zdeněk" i "Zdeněk Jirotka" -> "jirotka"."""
    if "," in author:
        return fold(author.split(",")[0])
    parts = fold(author).split()
    return parts[-1] if parts else ""


def pick(items: list[dict[str, Any]], title: str, author: str) -> dict[str, Any] | None:
    """První české vydání se stejným názvem a autorem, které má popis."""
    want_title, want_author = _clean_title(title), _surname(author)
    if not want_title or not want_author:
        return None
    for item in items:
        info = item.get("volumeInfo") or {}
        if info.get("language") != "cs" or not info.get("description"):
            continue
        if _clean_title(info.get("title") or "") != want_title:
            continue
        if not any(want_author in fold(a).split() for a in info.get("authors") or []):
            continue
        return info
    return None


async def describe(title: str, author: str | None) -> str | None:
    """Popis knihy, nebo None (bez klíče, bez autora, bez jisté shody)."""
    key = _key()
    if not key or not author or not title:
        return None
    cache_key = f"spoken:describe:v1:{_clean_title(title)}:{_surname(author)}"

    async def build() -> dict[str, Any]:
        resp = await _http.get(URL, params={"q": f"{_clean_title(title)} {_surname(author)}", "maxResults": 10, "key": key})
        resp.raise_for_status()  # 429 / 503 se neukládá -- příště znovu
        info = pick(resp.json().get("items") or [], title, author)
        return {"description": (info or {}).get("description")}

    try:
        return (await cached_json(cache_key, TTL_S, build)).get("description")
    except (httpx.HTTPError, ValueError) as exc:
        logger.info("google books %s: %s", title, exc)
        return None


def pick_cover(items: list[dict[str, Any]], title: str, author: str) -> str | None:
    """Obal prvního českého vydání se stejným názvem a autorem (největší
    dostupná velikost); přísně jako `pick`, jen popis není potřeba."""
    want_title, want_author = _clean_title(title), _surname(author)
    if not want_title or not want_author:
        return None
    for item in items:
        info = item.get("volumeInfo") or {}
        links = info.get("imageLinks") or {}
        if info.get("language") != "cs" or not links:
            continue
        if _clean_title(info.get("title") or "") != want_title:
            continue
        if not any(want_author in fold(a).split() for a in info.get("authors") or []):
            continue
        url = next((links[k] for k in ("extraLarge", "large", "medium", "small", "thumbnail") if links.get(k)), None)
        if url:
            return url.replace("http://", "https://").replace("&edge=curl", "")
    return None


async def cover_image(title: str, author: str, dest: Path) -> bool:
    """Obal knihy z Google Books do `dest` (jen jistá shoda). Bez klíče nic."""
    key = _key()
    if not key or not author or not title:
        return False
    resp = await _http.get(URL, params={"q": f"{_clean_title(title)} {_surname(author)}", "maxResults": 10, "key": key})
    resp.raise_for_status()
    url = pick_cover(resp.json().get("items") or [], title, author)
    if not url:
        return False
    img = await _http.get(url, follow_redirects=True)
    if img.status_code != 200 or len(img.content) < 2000 or not img.headers.get("content-type", "").startswith("image/"):
        return False
    dest.parent.mkdir(parents=True, exist_ok=True)
    dest.write_bytes(img.content)
    return True
