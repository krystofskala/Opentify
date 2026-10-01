"""Import z odkazu na YouTube (video nebo playlist).

Na rozdíl od Spotify/Apple Music YouTube nic neříká o tom, CO odkaz je --
proto dva kroky:

1. `inspect_youtube_link` -- název, kanál, videa (yt-dlp, jen metadata).
2. `import_youtube_link(kind=...)` podle volby uživatele:
   - `track`    -- jedna skladba k přehrání,
   - `playlist` -- playlist v Knihovně (Sdílené),
   - `album`    -- album interpreta, které jinde není (neoficiální / jen na
                   YouTube) -> objeví se v jeho diskografii se štítkem,
   - `live`     -- koncert interpreta (stejně jako album, štítek Živě).
   - `soundtrack` -- hudba k filmu/seriálu/hře jako album; každá skladba
                   si nechá svého interpreta (u soundtracku hraje každý jiný).

Skladby nesou `external_refs.youtubeId` -> worker stáhne PŘESNĚ to video
(žádné hledání, žádný Soulseek). YouTube jde napřímo (volba uživatele,
viz YTDLP_PROXY), jako u stahování.
"""

from __future__ import annotations

import asyncio
import re
from typing import Any

import httpx
from sqlmodel import Session, select

from app.catalog.embedded_art import URL_TEMPLATE, _save_resized, artwork_path
from app.library.matching import find_or_create_artist, find_or_create_recording
from app.library.spotify_import import _get_or_create_playlist
from app.models import MediaAsset, MediaAssetStatus, PlaylistItem, Recording, Release

_VIDEO = re.compile(r"(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})")
_LIST = re.compile(r"[?&]list=([A-Za-z0-9_-]+)")


class YoutubeLinkError(Exception):
    """Chyba s českou zprávou pro uživatele."""


def is_youtube_url(text: str) -> bool:
    return bool(re.search(r"(youtube\.com|youtu\.be)/", text or ""))


def _clean_channel(name: str | None) -> str:
    # "Twenty One Pilots - Topic", "LanaDelReyVEVO" -> jméno interpreta.
    name = re.sub(r"\s*-\s*Topic$", "", name or "").strip()
    return re.sub(r"VEVO$", "", name).strip()


def _split_title(title: str, channel: str) -> tuple[str, str]:
    """„Interpret - Název (Official Video)" -> (interpret, název)."""
    clean = re.sub(r"\s*[\(\[][^\)\]]*(official|video|audio|lyric|visuali[sz]er|hd|4k)[^\)\]]*[\)\]]", "", title, flags=re.I)
    clean = clean.strip()
    parts = re.split(r"\s+[-–—]\s+", clean, maxsplit=1)
    if len(parts) == 2 and parts[0] and parts[1]:
        return parts[0].strip(), parts[1].strip()
    return channel, clean or title


def _extract(url: str) -> dict[str, Any]:
    import yt_dlp

    from app.providers import _ytdlp_proxy_opts

    opts = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist", "socket_timeout": 20, **_ytdlp_proxy_opts()}
    with yt_dlp.YoutubeDL(opts) as ydl:
        return ydl.extract_info(url, download=False) or {}


def _normalized_url(text: str) -> str:
    """Playlist má přednost (odkaz z playlistu nese i `v=`)."""
    lst = _LIST.search(text or "")
    if lst and not lst.group(1).startswith(("RD", "UL")):  # RD* = automatický mix, ne playlist
        return f"https://www.youtube.com/playlist?list={lst.group(1)}"
    video = _VIDEO.search(text or "")
    if video:
        return f"https://www.youtube.com/watch?v={video.group(1)}"
    raise YoutubeLinkError("Tohle nevypadá jako odkaz na YouTube video nebo playlist.")


async def inspect_youtube_link(text: str) -> dict[str, Any]:
    url = _normalized_url(text)
    try:
        info = await asyncio.to_thread(_extract, url)
    except Exception as exc:  # noqa: BLE001 -- yt-dlp chyby jsou různé
        raise YoutubeLinkError("YouTube odkaz se nepodařilo načíst (soukromé nebo smazané video?).") from exc
    is_playlist = info.get("_type") == "playlist" or bool(info.get("entries"))
    channel = _clean_channel(info.get("channel") or info.get("uploader"))
    entries = [e for e in (info.get("entries") or []) if e and e.get("id")] if is_playlist else [info]
    videos = []
    for e in entries:
        e_channel = _clean_channel(e.get("channel") or e.get("uploader")) or channel
        artist, title = _split_title(e.get("title") or "", e_channel)
        videos.append({"id": e["id"], "title": title, "artist": artist, "duration": e.get("duration")})
    thumbs = info.get("thumbnails") or []
    thumb = thumbs[-1].get("url") if thumbs else info.get("thumbnail")
    if not thumb and videos:
        thumb = f"https://i.ytimg.com/vi/{videos[0]['id']}/hqdefault.jpg"
    return {
        "url": url,
        "kind": "playlist" if is_playlist else "video",
        "title": info.get("title") or "",
        "channel": channel,
        # Návrh interpreta: nejčastější interpret videí, jinak kanál.
        "artist": max({v["artist"] for v in videos}, key=lambda a: sum(v["artist"] == a for v in videos), default=channel),
        "thumbnail": thumb,
        "videos": videos,
    }


_NOISE = re.compile(
    r"\b(soundtrack|ost|score|official|video|audio|lyrics?|hd|hq|4k|full|theme song|main theme|music|"
    r"original motion picture|from the motion picture|movie)\b|[#№]\s*\d+|\b\d{1,2}\.\s|[\[\]\(\)\-–—|♫'\"]",
    re.I,
)


_COVER_MARKERS = (
    "cover", "version", "piano", "karaoke", "tribute", "from \"", "from “", "in the style of",
    "remake", "orchestra", "film band", "lullaby", "8-bit", "instrumental",
)


def _words(text: str) -> set[str]:
    from app.catalog.deezer_ingest import norm

    return {w for w in (norm(t) for t in re.findall(r"\w+", text or "")) if len(w) > 1}


async def _match_catalog(session: Session, video: dict, channel: str) -> Recording | None:
    """Fanouškovská videa nesou místo interpreta jméno kanálu -- zkusit
    oficiální skladbu v katalogu (Deezer). Uznat jen jistou shodu: název
    skladby je v názvu videa A z videa je poznat i interpret nebo album
    (živě: "#12 Time (Hans Zimmer)" na kanálu "Inception Soundtrack HD")."""
    from app.catalog.deezer import get_deezer_client
    from app.catalog.deezer_ingest import ingest_track_with_context

    raw = f"{video['artist']} {video['title']}"
    text_words = _words(f"{raw} {channel}")

    def clean(text: str) -> str:
        return re.sub(r"\s+", " ", _NOISE.sub(" ", text)).strip()

    # Nejdřív jen název videa (jméno kanálu hledání kazí), pak s "interpretem".
    hits: list[dict] = []
    for query in dict.fromkeys(q for q in (clean(video["title"]), clean(raw)) if q):
        hits += await get_deezer_client().search_typed("track", query, 5) or []
    for hit in hits:
        title_words = _words(re.sub(r"\(.*?\)|-.*$", "", hit.get("title") or ""))
        if not title_words or not title_words <= text_words:
            continue
        artist_words = _words((hit.get("artist") or {}).get("name") or "")
        album_words = _words(re.sub(r"\(.*?\)", "", (hit.get("album") or {}).get("title") or "")) - {"the", "and", "of"}
        hit_text = f"{hit.get('title') or ''} {(hit.get('album') or {}).get('title') or ''} {(hit.get('artist') or {}).get('name') or ''}".lower()
        video_text = raw.lower()
        # Covery / klavírní verze / "(From X)" kompilace -- ne, pokud je
        # nemá i samotné video (živě: Augustin C, The Film Band...).
        if any(m in hit_text and m not in video_text for m in _COVER_MARKERS):
            continue
        artist_ok = bool(artist_words) and artist_words <= text_words
        album_title = ((hit.get("album") or {}).get("title") or "").lower()
        official_ost = any(m in album_title for m in ("soundtrack", "original", "motion picture", "score"))
        album_ok = (
            official_ost
            and len(album_words) >= 1
            and len(album_words & text_words) >= max(1, (len(album_words) + 1) // 2)
        )
        duration = video.get("duration")
        length_ok = not duration or not hit.get("duration") or abs(hit["duration"] - duration) <= max(20, duration * 0.25)
        if (artist_ok or album_ok) and length_ok:
            return ingest_track_with_context(session, hit)
    return None


def _has_file(session: Session, recording_id: str) -> bool:
    asset = session.get(MediaAsset, recording_id)
    return asset is not None and asset.status == MediaAssetStatus.AVAILABLE


async def _fetch_cover(url: str | None) -> bytes | None:
    if not url:
        return None
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            resp = await client.get(url)
        return resp.content if resp.status_code == 200 and len(resp.content) < 5 * 1024 * 1024 else None
    except httpx.HTTPError:
        return None


async def import_youtube_link(
    session: Session,
    user_id: str,
    text: str,
    *,
    kind: str,
    artist_name: str | None = None,
    title: str | None = None,
    year: int | None = None,
) -> dict[str, Any]:
    if kind not in ("track", "playlist", "album", "live", "soundtrack"):
        raise YoutubeLinkError("Neznámý druh importu.")
    info = await inspect_youtube_link(text)
    videos = info["videos"]
    if not videos:
        raise YoutubeLinkError("V odkazu nejsou žádná videa.")
    source_id = re.sub(r".*[?&](?:list|v)=", "", info["url"])

    if kind == "track":
        v = videos[0]
        artist = find_or_create_artist(session, artist_name or v["artist"])
        recording = find_or_create_recording(
            session, artist, title or v["title"], duration_ms=int(v["duration"] * 1000) if v.get("duration") else None
        )
        if not _has_file(session, recording.id):
            recording.external_refs = {**(recording.external_refs or {}), "youtubeId": v["id"]}
            session.add(recording)
        session.commit()
        return {"kind": "track", "recordingId": recording.id}

    if kind == "playlist":
        playlist = _get_or_create_playlist(session, user_id, f"youtube-link:playlist:{source_id}", title or info["title"])
        playlist.description = f"Z YouTube · {info['channel']}" if info["channel"] else "Z YouTube"
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all():
            session.delete(item)
        matched = 0
        for position, v in enumerate(videos):
            # Oficiální skladba z katalogu (správný interpret/album/obal),
            # jinak to video s interpretem z názvu/kanálu.
            recording = await _match_catalog(session, v, info["channel"])
            if recording is not None:
                matched += 1
            else:
                artist = find_or_create_artist(session, v["artist"])
                recording = find_or_create_recording(
                    session, artist, v["title"], duration_ms=int(v["duration"] * 1000) if v.get("duration") else None
                )
                if not _has_file(session, recording.id):
                    recording.external_refs = {**(recording.external_refs or {}), "youtubeId": v["id"]}
                    session.add(recording)
            session.add(PlaylistItem(playlist_id=playlist.id, recording_id=recording.id, position=position))
        cover = await _fetch_cover(info["thumbnail"])
        if cover and _save_resized(cover, artwork_path(playlist.id)):
            playlist.cover_urls = [URL_TEMPLATE.format(release_id=playlist.id)]
        session.add(playlist)
        session.commit()
        return {"kind": "playlist", "playlistId": playlist.id, "count": len(videos), "matched": matched}

    # album / live: vlastní vydání interpreta -- skladby VŽDY nové a navázané
    # na tohle vydání (stejný název jako studiová verze != stejná nahrávka).
    artist = find_or_create_artist(session, artist_name or info["artist"])
    release_title = title or info["title"]
    release = session.exec(
        select(Release).where(Release.artist_id == artist.id, Release.title == release_title)
    ).first()
    if release is None:
        release = Release(artist_id=artist.id, title=release_title, release_type="album")
        session.add(release)
        session.flush()
    release.external_refs = {
        **(release.external_refs or {}),
        "source": "youtube",
        "youtubeSource": source_id,
        "unofficial": True,
        "live": kind == "live",
        "soundtrack": kind == "soundtrack",
        "notes": {
            "live": "Živě · z YouTube",
            "soundtrack": "Soundtrack · z YouTube",
        }.get(kind, "Neoficiální vydání · jen na YouTube"),
    }
    if year and 1900 <= year <= 2100:
        release.release_date = str(year)  # neoficiální album: rok zadaný ručně
    for number, v in enumerate(videos, start=1):
        recording = session.exec(
            select(Recording).where(Recording.release_id == release.id, Recording.track_number == number)
        ).first()
        # Soundtrack: interpret skladby z názvu videa (album je "Various").
        track_artist = find_or_create_artist(session, v["artist"]) if kind == "soundtrack" and v["artist"] else artist
        if recording is None:
            recording = Recording(artist_id=track_artist.id, release_id=release.id, title=v["title"], track_number=number)
        recording.artist_id = track_artist.id
        recording.title = v["title"]
        recording.duration_ms = int(v["duration"] * 1000) if v.get("duration") else recording.duration_ms
        recording.external_refs = {**(recording.external_refs or {}), "youtubeId": v["id"]}
        session.add(recording)
    cover = await _fetch_cover(info["thumbnail"])
    if cover and _save_resized(cover, artwork_path(release.id)):
        release.images = [URL_TEMPLATE.format(release_id=release.id)]
    session.add(release)
    session.commit()
    return {"kind": kind, "releaseId": release.id, "artistId": artist.id, "count": len(videos)}
