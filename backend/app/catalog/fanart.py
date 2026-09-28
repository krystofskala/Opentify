"""fanart.tv -- široké fotky interpretů pro hlavičku detailu (`artistbackground`,
typicky 1920x1080) a čtvercové fotky (`artistthumb`) jako záloha k Deezeru.

Volitelné: bez `FANART_API_KEY` v .env se nic nevolá (klíč je zdarma na
fanart.tv, osobní použití). Potřebuje MusicBrainz ID interpreta.
"""

from __future__ import annotations

import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
from sqlmodel import Session, select

from app.catalog.cache import cached_json
from app.db import engine
from app.models import Artist

logger = logging.getLogger(__name__)

FANART_BASE = "https://webservice.fanart.tv/v3/music"
_CHECKED_KEY = "bannerCheckedAt"
_RECHECK_AFTER = timedelta(days=14)
_TTL_SECONDS = 7 * 24 * 60 * 60

_http = httpx.AsyncClient(timeout=12.0)


def fanart_api_key() -> str | None:
    return os.environ.get("FANART_API_KEY") or None


def _best(images: list[dict[str, Any]] | None) -> str | None:
    """Nejoblíbenější obrázek (fanart.tv `likes`), při shodě první v pořadí."""
    ranked = sorted(images or [], key=lambda img: -int(img.get("likes") or 0))
    return next((img["url"] for img in ranked if img.get("url")), None)


def pick_banner_and_thumb(data: dict[str, Any] | None) -> tuple[str | None, str | None]:
    if not data:
        return None, None
    return _best(data.get("artistbackground")), _best(data.get("artistthumb"))


async def fetch_artist_art(mbid: str) -> dict[str, Any] | None:
    key = fanart_api_key()
    if not key:
        return None

    async def fetch() -> dict[str, Any]:
        resp = await _http.get(f"{FANART_BASE}/{mbid}", params={"api_key": key})
        if resp.status_code == 404:
            return {}  # interpret na fanart.tv není -- cachovat jako "nic"
        resp.raise_for_status()
        return resp.json()

    try:
        return await cached_json(f"fanart:{mbid}", _TTL_SECONDS, fetch)
    except (httpx.HTTPError, ValueError) as exc:
        logger.info("fanart.tv selhal pro %s: %s", mbid, exc)
        return None


def _recently_checked(refs: dict[str, Any]) -> bool:
    stamp = refs.get(_CHECKED_KEY)
    if not stamp:
        return False
    try:
        return datetime.now(timezone.utc) - datetime.fromisoformat(stamp) < _RECHECK_AFTER
    except ValueError:
        return False


async def fill_artist_banner(artist_id: str, *, force: bool = False) -> bool:
    """Doplní `external_refs.bannerUrl` (a fotku, když chybí). Vrací `True`,
    když se něco změnilo. Bez klíče / bez MBID / nedávno zkontrolováno -> nic."""
    if not fanart_api_key():
        return False
    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None or not artist.mbid:
            return False
        refs = artist.external_refs or {}
        if refs.get("bannerUrl") or (not force and _recently_checked(refs)):
            return False
        mbid = artist.mbid

    data = await fetch_artist_art(mbid)
    if data is None:
        return False  # síťová chyba -- zkusit příště, neoznačovat jako zkontrolované
    banner, thumb = pick_banner_and_thumb(data)

    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None:
            return False
        refs = {**(artist.external_refs or {}), _CHECKED_KEY: datetime.now(timezone.utc).isoformat()}
        if banner:
            refs["bannerUrl"] = banner
        artist.external_refs = refs
        if thumb and not artist.images:
            artist.images = [thumb]
        session.add(artist)
        session.commit()
    return bool(banner or thumb)


def pending_banner_artist_ids(session: Session, library_artist_ids: set[str], limit: int) -> list[str]:
    if not fanart_api_key():
        return []
    candidates = [
        a
        for a in session.exec(select(Artist).where(Artist.mbid.is_not(None))).all()  # type: ignore[union-attr]
        if not (a.external_refs or {}).get("bannerUrl") and not _recently_checked(a.external_refs or {})
    ]
    candidates.sort(key=lambda a: a.id not in library_artist_ids)
    return [a.id for a in candidates[:limit]]

