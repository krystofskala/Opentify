"""Plné tagy do stažených souborů (`/data/media`) z katalogu -- co zjistíme
při párování, nezahazovat: název, interpret, album, interpret alba, číslo
stopy (z kolika), rok, žánr, ISRC, ID z MusicBrainz/Deezeru, obal a text.

Vlastní knihovna uživatele (`/data/local-music`) se NEMĚNÍ -- jen soubory,
které jsme stáhli my. Zápis přes kopii + `os.replace`, ať rozehrané
přehrávání nečte napůl přepsaný soubor. Co je v souboru, se pamatuje jako
otisk metadat (`tagsHash`) -- přepíše se jen po změně v katalogu.
"""

from __future__ import annotations

import base64
import hashlib
import json
import logging
import os
import shutil
from pathlib import Path
from typing import Any

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording, Release
from app.utils import sha256_file

logger = logging.getLogger("vault.file_tags")

MEDIA_ROOT = "/data/media/"
TAGS_VERSION = 1


def collect(session: Session, recording: Recording) -> dict[str, Any]:
    """Metadata skladby z katalogu (jen to, co opravdu známe)."""
    release = session.get(Release, recording.release_id) if recording.release_id else None
    artist = session.get(Artist, recording.artist_id) if recording.artist_id else None
    album_artist = session.get(Artist, release.artist_id) if release else None
    # Počet stop jen ze skutečného tracklistu alba (katalog ho mívá neúplný).
    total = (release.external_refs or {}).get("tracklistCount") if release else None
    local_art = Path(MEDIA_ROOT) / "artwork" / f"{release.id}.jpg" if release else None
    cover = str(local_art) if local_art and local_art.is_file() else ((release.images or [None])[0] if release else None)
    data: dict[str, Any] = {
        "v": TAGS_VERSION,
        "title": recording.title,
        "artist": artist.name if artist else None,
        "album": release.title if release else None,
        "albumArtist": album_artist.name if album_artist else None,
        "track": recording.track_number,
        "trackTotal": total,
        "date": (release.release_date or None) if release else None,
        "genre": (release.genres or [])[:3] if release else [],
        "isrc": recording.isrc,
        "mbRecording": recording.mbid if recording.mbid and not recording.mbid.startswith("own:") else None,
        "mbReleaseGroup": release.mbid if release and release.mbid and not release.mbid.startswith("own:") else None,
        "mbArtist": artist.mbid if artist and artist.mbid and not artist.mbid.startswith("own:") else None,
        "deezerTrack": recording.deezer_id,
        "artwork": cover,
    }
    return {k: v for k, v in data.items() if v not in (None, [], "")}


def signature(data: dict[str, Any]) -> str:
    raw = json.dumps(data, sort_keys=True, ensure_ascii=False)
    return hashlib.sha1(raw.encode()).hexdigest()[:16]


def _picture(data: dict[str, Any]) -> bytes | None:
    path = data.get("artwork")
    if path and path.startswith("http"):
        return _download_picture(path)
    if not path or not os.path.isfile(path):
        return None
    try:
        raw = Path(path).read_bytes()
    except OSError:
        return None
    return raw if 0 < len(raw) <= 2_000_000 else None


def _download_picture(url: str) -> bytes | None:
    """Obal z katalogu (Deezer / Cover Art Archive), max 2 MB."""
    import httpx

    try:
        resp = httpx.get(url, timeout=10.0, follow_redirects=True)
    except httpx.HTTPError:
        return None
    if resp.status_code != 200 or not resp.headers.get("content-type", "").startswith("image/jpeg"):
        return None
    return resp.content if 0 < len(resp.content) <= 2_000_000 else None


def _vorbis(data: dict[str, Any], lyrics: str | None) -> dict[str, list[str]]:
    tags: dict[str, list[str]] = {}

    def put(key: str, value: Any) -> None:
        if value not in (None, "", []):
            tags[key] = [str(v) for v in value] if isinstance(value, list) else [str(value)]

    put("TITLE", data.get("title"))
    put("ARTIST", data.get("artist"))
    put("ALBUM", data.get("album"))
    put("ALBUMARTIST", data.get("albumArtist"))
    put("TRACKNUMBER", data.get("track"))
    put("TRACKTOTAL", data.get("trackTotal"))
    put("DATE", data.get("date"))
    put("GENRE", data.get("genre"))
    put("ISRC", data.get("isrc"))
    put("MUSICBRAINZ_TRACKID", data.get("mbRecording"))
    put("MUSICBRAINZ_RELEASEGROUPID", data.get("mbReleaseGroup"))
    put("MUSICBRAINZ_ARTISTID", data.get("mbArtist"))
    put("DEEZER_TRACKID", data.get("deezerTrack"))
    put("LYRICS", lyrics)
    return tags


def _write_flac(path: Path, data: dict[str, Any], lyrics: str | None, picture: bytes | None) -> None:
    from mutagen.flac import FLAC, Picture

    audio = FLAC(path)
    for key, values in _vorbis(data, lyrics).items():
        audio[key] = values
    if picture:
        audio.clear_pictures()
        pic = Picture()
        pic.type, pic.mime, pic.data = 3, "image/jpeg", picture
        audio.add_picture(pic)
    audio.save()


def _write_ogg(path: Path, data: dict[str, Any], lyrics: str | None, picture: bytes | None) -> None:
    from mutagen import File as MutagenFile
    from mutagen.flac import Picture

    audio = MutagenFile(path)
    if audio is None:
        raise ValueError("neznámý formát")
    if audio.tags is None:
        audio.add_tags()
    for key, values in _vorbis(data, lyrics).items():
        audio[key] = values
    if picture:
        pic = Picture()
        pic.type, pic.mime, pic.data = 3, "image/jpeg", picture
        audio["METADATA_BLOCK_PICTURE"] = [base64.b64encode(pic.write()).decode("ascii")]
    audio.save()


def _write_mp3(path: Path, data: dict[str, Any], lyrics: str | None, picture: bytes | None) -> None:
    from mutagen.id3 import APIC, ID3, ID3NoHeaderError, TALB, TCON, TDRC, TIT2, TPE1, TPE2, TRCK, TSRC, TXXX, UFID, USLT

    try:
        id3 = ID3(path)
    except ID3NoHeaderError:
        id3 = ID3()
    text = {
        TIT2: data.get("title"),
        TPE1: data.get("artist"),
        TALB: data.get("album"),
        TPE2: data.get("albumArtist"),
        TDRC: data.get("date"),
        TSRC: data.get("isrc"),
    }
    for frame, value in text.items():
        if value:
            id3.setall(frame.__name__, [frame(encoding=3, text=[str(value)])])
    if data.get("track"):
        track = f"{data['track']}/{data['trackTotal']}" if data.get("trackTotal") else str(data["track"])
        id3.setall("TRCK", [TRCK(encoding=3, text=[track])])
    if data.get("genre"):
        id3.setall("TCON", [TCON(encoding=3, text=data["genre"])])
    for desc, key in (
        ("MusicBrainz Track Id", "mbRecording"),
        ("MusicBrainz Release Group Id", "mbReleaseGroup"),
        ("MusicBrainz Artist Id", "mbArtist"),
        ("Deezer Track Id", "deezerTrack"),
    ):
        if data.get(key):
            id3.setall(f"TXXX:{desc}", [TXXX(encoding=3, desc=desc, text=[str(data[key])])])
    if data.get("mbRecording"):
        id3.setall("UFID", [UFID(owner="http://musicbrainz.org", data=str(data["mbRecording"]).encode())])
    if lyrics:
        id3.setall("USLT", [USLT(encoding=3, lang="und", desc="", text=lyrics)])
    if picture:
        id3.setall("APIC", [APIC(encoding=3, mime="image/jpeg", type=3, desc="Cover", data=picture)])
    id3.save(path, v2_version=4)


def _write_m4a(path: Path, data: dict[str, Any], lyrics: str | None, picture: bytes | None) -> None:
    from mutagen.mp4 import MP4, MP4Cover, MP4FreeForm

    audio = MP4(path)
    for key, field in (("\xa9nam", "title"), ("\xa9ART", "artist"), ("\xa9alb", "album"), ("aART", "albumArtist"), ("\xa9day", "date")):
        if data.get(field):
            audio[key] = [str(data[field])]
    if data.get("genre"):
        audio["\xa9gen"] = [", ".join(data["genre"])]
    if data.get("track"):
        audio["trkn"] = [(int(data["track"]), int(data.get("trackTotal") or 0))]
    for desc, key in (
        ("ISRC", "isrc"),
        ("MusicBrainz Track Id", "mbRecording"),
        ("MusicBrainz Release Group Id", "mbReleaseGroup"),
        ("MusicBrainz Artist Id", "mbArtist"),
        ("Deezer Track Id", "deezerTrack"),
    ):
        if data.get(key):
            audio[f"----:com.apple.iTunes:{desc}"] = [MP4FreeForm(str(data[key]).encode())]
    if lyrics:
        audio["\xa9lyr"] = [lyrics]
    if picture:
        audio["covr"] = [MP4Cover(picture, imageformat=MP4Cover.FORMAT_JPEG)]
    audio.save()


_WRITERS = {".flac": _write_flac, ".mp3": _write_mp3, ".m4a": _write_m4a, ".ogg": _write_ogg, ".opus": _write_ogg}


def write(path: Path, data: dict[str, Any], lyrics: str | None) -> None:
    """Zapsat do kopie a tu atomicky prohodit (rozehraný stream čte dál starý soubor)."""
    writer = _WRITERS.get(path.suffix.lower())
    if writer is None:
        raise ValueError(f"formát {path.suffix} se netaguje")
    tmp = path.with_name(f".{path.name}.tagging")
    shutil.copy2(path, tmp)
    try:
        writer(tmp, data, lyrics, _picture(data))
        os.replace(tmp, path)
    finally:
        if tmp.exists():
            tmp.unlink()


async def _lyrics(data: dict[str, Any], duration_ms: int | None) -> str | None:
    from app.lyrics_service import fetch_lyrics

    try:
        found = await fetch_lyrics(
            track_name=data["title"],
            artist_name=data.get("artist"),
            album_name=data.get("album"),
            duration_s=duration_ms / 1000 if duration_ms else None,
        )
    except Exception:  # noqa: BLE001 - text je bonus
        return None
    if not found:
        return None
    # Časovaný (LRC) přednostně -- přehrávače ho umí zobrazit s časováním.
    return found.get("synced") or found.get("plain") or None


async def sweep(limit: int = 150) -> dict[str, int]:
    """Otaguje stažené soubory, jejichž metadata se od posledního zápisu
    změnila (nové stažení, oprava v katalogu)."""
    with Session(engine) as session:
        assets = session.exec(
            select(MediaAsset).where(
                MediaAsset.status == MediaAssetStatus.AVAILABLE,
                MediaAsset.storage_path.startswith(MEDIA_ROOT),  # type: ignore[union-attr]
            )
        ).all()
        todo: list[tuple[str, str, dict[str, Any], int | None]] = []
        for asset in assets:
            rec = session.get(Recording, asset.recording_id)
            if rec is None or Path(asset.storage_path).suffix.lower() not in _WRITERS:
                continue
            data = collect(session, rec)
            if (rec.external_refs or {}).get("tagsData") == signature(data):
                continue
            todo.append((rec.id, asset.storage_path, data, rec.duration_ms))
    done = failed = 0
    for rec_id, storage_path, data, duration_ms in todo[:limit]:
        lyrics = await _lyrics(data, duration_ms)
        path = Path(storage_path)
        try:
            await _to_thread(write, path, data, lyrics)
        except Exception as exc:  # noqa: BLE001 - jeden soubor nesmí zastavit ostatní
            failed += 1
            logger.info("tagy %s: %s", path.name, exc)
            continue
        size = path.stat().st_size
        checksum = await _to_thread(sha256_file, path)
        with Session(engine) as session:
            rec = session.get(Recording, rec_id)
            asset = session.get(MediaAsset, rec_id)
            if rec is None or asset is None or asset.storage_path != storage_path:
                continue
            rec.external_refs = {**(rec.external_refs or {}), "tagsData": signature(data), "tagsLyrics": bool(lyrics)}
            asset.filesize_bytes = size
            asset.checksum_sha256 = checksum
            session.add(rec)
            session.add(asset)
            session.commit()
        done += 1
    if todo:
        logger.info("tagy: zapsáno %d, chyb %d, zbývá %d", done, failed, max(0, len(todo) - limit))
    return {"done": done, "failed": failed, "left": max(0, len(todo) - limit)}


async def _to_thread(fn, *args):
    import asyncio

    return await asyncio.to_thread(fn, *args)
