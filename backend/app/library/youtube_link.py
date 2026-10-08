"""Import z odkazu na YouTube (video nebo playlist) nebo SoundCloud
(skladba, set, profil) -- obojí přes yt-dlp, stejný postup.

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
import logging
import re
from typing import Any

import httpx
from sqlmodel import Session, select

from app.catalog.embedded_art import URL_TEMPLATE, _save_resized, artwork_path
from app.library.matching import find_or_create_artist, find_or_create_recording
from app.library.spotify_import import _get_or_create_playlist
from app.models import MediaAsset, MediaAssetStatus, PlaylistItem, Recording, Release

logger = logging.getLogger("uvicorn.error")
_VIDEO = re.compile(r"(?:youtube\.com/(?:watch\?(?:.*&)?v=|shorts/|live/)|youtu\.be/)([A-Za-z0-9_-]{11})")
_LIST = re.compile(r"[?&]list=([A-Za-z0-9_-]+)")
_MIX_URL = re.compile(r"[?&]list=RD(?!CLAK)")
_MIX_LIMIT = 50
_BROWSE = re.compile(r"music\.youtube\.com/browse/(MPRE[A-Za-z0-9_-]+)")


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


# Řádek tracklistu v popisu: čas na začátku („00:00 Interpret - Skladba“,
# „1. [03:15] …“) nebo na konci („Interpret - Skladba 1:02:03“).
_TS = r"\[?\(?((?:\d{1,2}:)?\d{1,2}:\d{2})\)?\]?"
_LINE_START = re.compile(rf"^\s*(?:\d{{1,3}}[.)]\s*)?{_TS}\s*[-–—|.:)]*\s*(.+?)\s*$")
_LINE_END = re.compile(rf"^\s*(?:\d{{1,3}}[.)]\s*)?(.+?)\s*[-–—|]?\s*{_TS}\s*$")
_NOT_TRACKS = re.compile(r"^(intro|outro|start|začátek|konec|end|tracklist|break|interlude)\b", re.I)


def _seconds(stamp: str) -> int:
    total = 0
    for part in stamp.split(":"):
        total = total * 60 + int(part)
    return total


def tracklist(info: dict) -> list[dict]:
    """Skladby jednoho videa (DJ mix, set, kompilace): z kapitol, jinak
    z časů v popisu. Jen řádky „Interpret - Skladba“ (bez interpreta se
    v katalogu nedá nic jistě najít); nejméně 3, jinak to tracklist není."""
    rows: list[tuple[int, str]] = []
    for ch in info.get("chapters") or []:
        if ch.get("title") is not None and ch.get("start_time") is not None:
            rows.append((int(ch["start_time"]), str(ch["title"])))
    if len(rows) < 3:
        rows = []
        for line in (info.get("description") or "").splitlines():
            if m := _LINE_START.match(line):
                rows.append((_seconds(m.group(1)), m.group(2)))
            elif m := _LINE_END.match(line):
                rows.append((_seconds(m.group(2)), m.group(1)))
    rows.sort(key=lambda r: r[0])
    end = int(info.get("duration") or 0)
    out: list[dict] = []
    for i, (start, text) in enumerate(rows):
        text = re.sub(r"^\d{1,3}[.)]\s*", "", text).strip()
        parts = re.split(r"\s+[-–—]\s+", text, maxsplit=1)
        if len(parts) != 2 or not parts[0] or not parts[1] or _NOT_TRACKS.match(text):
            continue
        nxt = rows[i + 1][0] if i + 1 < len(rows) else end
        out.append({"artist": parts[0].strip(), "title": parts[1].strip(), "duration": (nxt - start) if nxt > start else None})
    return out if len(out) >= 3 else []


def _extract(url: str) -> dict[str, Any]:
    import yt_dlp

    from app.providers import _ytdlp_proxy_opts

    opts = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist", "socket_timeout": 20, **_ytdlp_proxy_opts()}
    with yt_dlp.YoutubeDL(opts) as ydl:
        return ydl.extract_info(url, download=False) or {}


def _normalized_url(text: str) -> str:
    """Playlist má přednost (odkaz z playlistu nese i `v=`)."""
    from app.soundcloud import normalized_url as sc_url

    if sc := sc_url(text):
        return sc
    lst = _LIST.search(text or "")
    # RD* / UL* = automatický mix k videu, ne playlist -- KROMĚ RDCLAK5uy*
    # (redakční playlisty a alba YouTube Music, živě: tátův odkaz "nevypadá
    # jako odkaz na YouTube").
    if lst and (lst.group(1).startswith("RDCLAK") or not lst.group(1).startswith(("RD", "UL"))):
        return f"https://www.youtube.com/playlist?list={lst.group(1)}"
    video = _VIDEO.search(text or "")
    if video:
        return f"https://www.youtube.com/watch?v={video.group(1)}"
    # Mix bez videa (sdílený "playlist" list=RD<id videa>): stránka playlistu
    # mixu je pro YouTube "unviewable" -- načíst přes video, ke kterému patří.
    if lst:
        mix = re.fullmatch(r"RD([A-Za-z0-9_-]{11})", lst.group(1))
        if mix:
            return f"https://www.youtube.com/watch?v={mix.group(1)}&list={lst.group(1)}"
        return f"https://www.youtube.com/playlist?list={lst.group(1)}"
    # Album / stránka YouTube Music (music.youtube.com/browse/MPREb_...) --
    # yt-dlp si ji převede na playlist alba sám.
    browse = _BROWSE.search(text or "")
    if browse:
        return f"https://music.youtube.com/browse/{browse.group(1)}"
    logger.info("odkaz na YouTube nerozpoznán: %s", (text or "")[:200])
    raise YoutubeLinkError("Tohle nevypadá jako odkaz na YouTube nebo SoundCloud.")


def _source(url: str) -> str:
    return "soundcloud" if "soundcloud.com" in url else "youtube"


def _ref(source: str, video: dict) -> dict[str, str]:
    """Kde worker skladbu přesně vezme."""
    return {"soundcloudUrl": video["url"]} if source == "soundcloud" else {"youtubeId": video["id"]}


_FROM = {"youtube": "z YouTube", "soundcloud": "ze SoundCloudu"}


async def inspect_youtube_link(text: str) -> dict[str, Any]:
    url = _normalized_url(text)
    source = _source(url)
    try:
        info = await asyncio.to_thread(_extract, url)
    except Exception as exc:  # noqa: BLE001 -- yt-dlp chyby jsou různé
        raise YoutubeLinkError("Odkaz se nepodařilo načíst (soukromé nebo smazané?).") from exc
    is_playlist = info.get("_type") == "playlist" or bool(info.get("entries"))
    channel = _clean_channel(info.get("channel") or info.get("uploader"))
    entries = [e for e in (info.get("entries") or []) if e and e.get("id")] if is_playlist else [info]
    if _MIX_URL.search(url):
        entries = entries[:_MIX_LIMIT]  # automatický mix je skoro nekonečný (živě 399)
    videos = []
    for e in entries:
        e_channel = _clean_channel(e.get("channel") or e.get("uploader")) or channel
        artist, title = _split_title(e.get("title") or "", e_channel)
        if source == "soundcloud":
            sc_url = e.get("webpage_url") or e.get("url")
            if not sc_url or (e.get("duration") is not None and e["duration"] <= 31):
                continue  # Go+ skladba (jen 30s ukázka)
            videos.append({"id": str(e.get("id")), "url": sc_url, "title": title, "artist": artist, "duration": e.get("duration")})
            continue
        videos.append({"id": e["id"], "title": title, "artist": artist, "duration": e.get("duration")})
    thumbs = info.get("thumbnails") or []
    thumb = thumbs[-1].get("url") if thumbs else info.get("thumbnail")
    if not thumb and videos and source == "youtube":
        thumb = f"https://i.ytimg.com/vi/{videos[0]['id']}/hqdefault.jpg"
 
    return {
        "url": url,
        "source": source,
        "kind": "playlist" if is_playlist else "video",
        # Jedno video s tracklistem (DJ mix, set): jde i jako playlist skladeb.
        "tracklist": [] if is_playlist else tracklist(info),
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
    source = info["source"]
    videos = info["videos"]
    if not videos:
        raise YoutubeLinkError("V odkazu nejsou žádné skladby (u SoundCloudu jen pro Go+?).")
    source_id = re.sub(r".*[?&](?:list|v)=", "", info["url"]) if source == "youtube" else info["url"]

    if kind == "track":
        v = videos[0]
        artist = find_or_create_artist(session, artist_name or v["artist"])
        recording = find_or_create_recording(
            session, artist, title or v["title"], duration_ms=int(v["duration"] * 1000) if v.get("duration") else None
        )
        if not _has_file(session, recording.id):
            recording.external_refs = {**(recording.external_refs or {}), **_ref(source, v)}
            session.add(recording)
        session.commit()
        return {"kind": "track", "recordingId": recording.id}

    if kind == "playlist" and info["kind"] == "video":
        # Jedno video jako playlist: skladby z jeho tracklistu (kapitoly /
        # popis) -- napárované na katalog, jinak běžné obstarání podle jména.
        videos = info["tracklist"]
        if not videos:
            raise YoutubeLinkError("Video nemá tracklist (kapitoly ani časy v popisu) – jako playlist nejde.")
        info = {**info, "videos": videos}

    if kind == "playlist":
        playlist = _get_or_create_playlist(session, user_id, f"{source}-link:playlist:{source_id}", title or info["title"])
        label = _FROM[source][0].upper() + _FROM[source][1:]
        playlist.description = f"{label} · {info['channel']}" if info["channel"] else label
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
                # Skladba z tracklistu videa nemá vlastní video -- obstará se
                # běžně podle jména.
                if not _has_file(session, recording.id) and v.get("id"):
                    recording.external_refs = {**(recording.external_refs or {}), **_ref(source, v)}
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
    # Jen dřívější YouTube import téhož alba -- oficiální vydání stejného
    # jména se nesmí přepsat (a pak smazat jako "z YouTube").
    release = next(
        (
            r
            for r in session.exec(
                select(Release).where(Release.artist_id == artist.id, Release.title == release_title)
            ).all()
            if (r.external_refs or {}).get("source") == source
        ),
        None,
    )
    if release is None:
        release = Release(artist_id=artist.id, title=release_title, release_type="album")
        session.add(release)
        session.flush()
    release.external_refs = {
        **(release.external_refs or {}),
        "source": source,
        "youtubeSource": source_id,
        "unofficial": True,
        "live": kind == "live",
        "soundtrack": kind == "soundtrack",
        "notes": {
            "live": f"Živě · {_FROM[source]}",
            "soundtrack": f"Soundtrack · {_FROM[source]}",
        }.get(kind, "Neoficiální vydání · jen " + ("na YouTube" if source == "youtube" else "na SoundCloudu")),
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
        recording.external_refs = {**(recording.external_refs or {}), **_ref(source, v)}
        session.add(recording)
    cover = await _fetch_cover(info["thumbnail"])
    if cover and _save_resized(cover, artwork_path(release.id)):
        release.images = [URL_TEMPLATE.format(release_id=release.id)]
    session.add(release)
    session.commit()
    return {"kind": kind, "releaseId": release.id, "artistId": artist.id, "count": len(videos)}
