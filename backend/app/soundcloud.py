"""SoundCloud přes yt-dlp (oficiální API je jen pro schválené aplikace
s předplatným Artist Pro). Dema, živáky, remixy a nevydané věci, které na
Deezeru/Spotify nejsou.

Použití: poslední záloha stahování (providers.SoundcloudProvider), import
odkazem (library/youtube_link.py), "Nevydané a vzácné" u interpreta
(z jeho oficiálního profilu podle MusicBrainz) a filtr SoundCloud v Hledat.

Skladby jen pro Go+ dávají jen 30s ukázku (formát `*_preview`) -- ty se
vynechávají. Síť jako YouTube (`YTDLP_PROXY`, je-li nastavený).
"""

from __future__ import annotations

import asyncio
import re
from typing import Any

from sqlmodel import Session, select

from app.catalog.cache import cached_json

DAY = 24 * 60 * 60
_SC_URL = re.compile(r"https?://(?:www\.|m\.)?soundcloud\.com/[^\s?#]+", re.I)
_SHORT_URL = re.compile(r"https?://on\.soundcloud\.com/[A-Za-z0-9]+", re.I)


def is_soundcloud_url(text: str) -> bool:
    return bool(_SC_URL.search(text or "") or _SHORT_URL.search(text or ""))


def normalized_url(text: str) -> str | None:
    m = _SC_URL.search(text or "") or _SHORT_URL.search(text or "")
    if not m:
        return None
    url = m.group(0).rstrip("/")
    return re.sub(r"^https?://(?:www\.|m\.)", "https://", url)


def _opts(**extra: Any) -> dict[str, Any]:
    from app.providers import _ytdlp_proxy_opts

    return {"quiet": True, "no_warnings": True, "socket_timeout": 20, **_ytdlp_proxy_opts(), **extra}


def _entry(e: dict[str, Any]) -> dict[str, Any] | None:
    """Plochý záznam yt-dlp -> {url, title, uploader, duration, thumbnail}."""
    url = e.get("webpage_url") or e.get("url")
    duration = e.get("duration")
    if not url or not e.get("title"):
        return None
    # Go+ skladby mají jen 30s ukázku.
    if duration is not None and duration <= 31:
        return None
    thumbs = e.get("thumbnails") or []
    return {
        "url": url,
        "title": e["title"],
        "uploader": e.get("uploader") or "",
        "duration": duration,
        "thumbnail": (thumbs[-1].get("url") if thumbs else None) or e.get("thumbnail"),
    }


def _extract(url: str, flat: bool = True) -> dict[str, Any]:
    import yt_dlp

    opts = _opts(extract_flat="in_playlist") if flat else _opts()
    with yt_dlp.YoutubeDL(opts) as ydl:
        return ydl.extract_info(url, download=False) or {}


async def search(query: str, limit: int = 10) -> list[dict[str, Any]]:
    async def fetch() -> list[dict[str, Any]]:
        try:
            info = await asyncio.to_thread(_extract, f"scsearch{limit + 5}:{query}")
        except Exception:  # noqa: BLE001 -- yt-dlp chyby jsou různé
            return []
        return [x for x in (_entry(e) for e in info.get("entries") or [] if e) if x][:limit]

    return await cached_json(f"sc:search:{query.strip().lower()}:{limit}", DAY, fetch, is_empty=lambda v: not v)


def _track_details(ids: list[str]) -> dict[str, dict[str, Any]]:
    """Délka a pravidla skladeb po 50 jedním dotazem (plochý výpis profilu
    je nemá). {} když se nepovede -- pak se nefiltruje."""
    import yt_dlp

    out: dict[str, dict[str, Any]] = {}
    with yt_dlp.YoutubeDL(_opts()) as ydl:
        ie = ydl.get_info_extractor("Soundcloud")
        ie.initialize()
        for i in range(0, len(ids), 50):
            data = ie._call_api(
                "https://api-v2.soundcloud.com/tracks", None, query={"ids": ",".join(ids[i : i + 50])}, note=False
            )
            for t in data or []:
                out[str(t.get("id"))] = t
    return out


async def profile_tracks(profile_url: str, limit: int = 60) -> list[dict[str, Any]]:
    """Nahrané skladby profilu (nejnovější první), bez Go+ ukázek."""

    async def fetch() -> list[dict[str, Any]]:
        try:
            info = await asyncio.to_thread(_extract, profile_url.rstrip("/") + "/tracks")
        except Exception:  # noqa: BLE001
            return []
        raw = [e for e in (info.get("entries") or [])[: limit * 2] if e]
        try:
            details = await asyncio.to_thread(_track_details, [str(e["id"]) for e in raw if e.get("id")])
        except Exception:  # noqa: BLE001 -- bez podrobností jako dřív
            details = {}
        entries = []
        for e in raw:
            d = details.get(str(e.get("id")))
            if d is not None:
                # Go+ (policy SNIP) = jen 30s ukázka. Na oficiálním profilu to
                # bývají i cizí skladby od distributora (u Prince pandžábský
                # zpěvák stejného jména -- #76).
                if d.get("policy") == "SNIP":
                    continue
                if d.get("duration"):
                    e = {**e, "duration": d["duration"] / 1000}
            entries.append(e)
        return [x for x in (_entry(e) for e in entries) if x][:limit]

    return await cached_json(f"sc:profile:v2:{profile_url}", DAY, fetch, is_empty=lambda v: not v)


def recording_for(session: Session, artist: Any, item: dict[str, Any]) -> Any:
    """Skladba ze SoundCloudu jako naše nahrávka (worker ji stáhne přesně
    z toho odkazu). `artist` = náš interpret, nebo jméno (uploader)."""
    from app.library.matching import find_or_create_artist, find_or_create_recording
    from app.models import MediaAsset, MediaAssetStatus

    if isinstance(artist, str):
        artist = find_or_create_artist(session, artist or "SoundCloud")
    recording = find_or_create_recording(
        session, artist, item["title"], duration_ms=int(item["duration"] * 1000) if item.get("duration") else None
    )
    asset = session.get(MediaAsset, recording.id)
    if asset is None or asset.status != MediaAssetStatus.AVAILABLE:
        recording.external_refs = {**(recording.external_refs or {}), "soundcloudUrl": item["url"]}
        session.add(recording)
    return recording


def artist_profile(session: Session, artist_id: str, relations: list[dict[str, Any]] | None) -> str | None:
    """Oficiální SoundCloud profil interpreta: ručně zadaný
    (`external_refs.soundcloud`), jinak odkaz z MusicBrainz -- nikdy hledání
    podle jména (cizí jmenovci)."""
    from app.models import Artist

    artist = session.get(Artist, artist_id)
    manual = ((artist.external_refs or {}) if artist else {}).get("soundcloud")
    if manual:
        return manual
    for rel in relations or []:
        url = ((rel.get("url") or {}).get("resource") or "").strip()
        if "soundcloud.com/" in url and not rel.get("ended"):
            return normalized_url(url)
    return None


def official_titles(session: Session, artist_id: str) -> set[str]:
    """Názvy skladeb z oficiální diskografie (i s verzí v závorce)."""
    from app.catalog.deezer_ingest import version_key
    from app.models import Recording

    return {
        version_key(r.title)
        for r in session.exec(select(Recording).where(Recording.artist_id == artist_id)).all()
        if r.deezer_id or r.mbid
    }


def clean_title(title: str, artist_name: str) -> str:
    """"Billy Strings - Live to Tell" na jeho profilu -> "Live to Tell"."""
    parts = re.split(r"\s+[-–—]\s+", title, maxsplit=1)
    if len(parts) == 2 and parts[0].strip().lower() == artist_name.strip().lower():
        return parts[1].strip()
    return title.strip()
