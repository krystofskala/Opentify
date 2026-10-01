"""Deezer JSON -> lokální Artist/Release/Recording řádky.

Hledání, žebříčky a playlisty na Domů jdou přes Deezer (rychlý, bez klíče,
~50 req/5 s) místo MusicBrainz (1 req/s) -- MBID se dohledává až líně.
Pořadí párování na existující řádky, ať opakované hledání ani skladba, co
už je v knihovně, nikdy nevytvoří duplikát:

  interpret:  deezer_id -> přesné jméno (bez deezer_id / se stejným)
  album:      deezer_id -> stejný interpret + normalizovaný název
  skladba:    deezer_id -> ISRC -> stejný interpret + normalizovaný název

Funkce jsou čistě synchronní a NIC neawaitují -- volající je spouští v
event loopu mezi `await`y, takže dva souběžné requesty (klient posílá 3
typy hledání naráz) se v nich nemůžou proložit a založit stejného
interpreta dvakrát. Commit dělá volající jednou na konci dávky.
"""

from __future__ import annotations

import re
import unicodedata
from typing import Any

from sqlalchemy import func
from sqlmodel import Session, select

from app.models import Artist, Recording, Release
from app.utils import utcnow


# Výchozí šedá silueta Deezeru (interpret/album bez obrázku): prázdný hash
# v adrese, nebo md5 prázdného souboru -- nebrat jako skutečný obrázek.
_DZ_EMPTY = "d41d8cd98f00b204e9800998ecf8427e"


def deezer_image(url: str | None) -> str | None:
    if not url or _DZ_EMPTY in url or re.search(r"/images/(artist|cover)//", url):
        return None
    return url

_PARENS_RE = re.compile(r"\(.*?\)|\[.*?\]")
_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")

_RECORD_TYPE = {"album": "album", "single": "single", "ep": "ep", "compile": "compilation"}


def norm(text: str | None) -> str:
    if not text:
        return ""
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii").lower()
    text = _PARENS_RE.sub(" ", text)
    return _NON_ALNUM_RE.sub("", text)


def is_placeholder_picture(url: str | None) -> bool:
    return not url or "/artist//" in url or "/cover//" in url


def ingest_artist(session: Session, dz: dict[str, Any]) -> Artist | None:
    name = (dz.get("name") or "").strip()
    if not dz.get("id") or not name:
        return None
    dzid = str(dz["id"])
    artist = session.exec(select(Artist).where(Artist.deezer_id == dzid)).first()
    if artist is None:
        candidates = session.exec(select(Artist).where(func.lower(Artist.name) == name.lower())).all()
        # Přednost interpretovi s MBID (knihovna/MusicBrainz), ať se hledání
        # napojí na existující diskografii a přehratelné skladby.
        candidates.sort(key=lambda a: a.mbid is None)
        artist = next((a for a in candidates if a.deezer_id in (None, dzid)), None)
    if artist is None:
        artist = Artist(name=name, sort_name=name, deezer_id=dzid)
    else:
        artist.deezer_id = artist.deezer_id or dzid
        artist.updated_at = utcnow()
    picture = deezer_image(dz.get("picture_xl") or dz.get("picture_big"))
    has_photo = bool(artist.images) and not is_placeholder_picture(artist.images[0])
    if not has_photo and not is_placeholder_picture(picture):
        artist.images = [picture]
    session.add(artist)
    return artist


def ingest_album(session: Session, dz: dict[str, Any], artist: Artist) -> Release | None:
    title = (dz.get("title") or "").strip()
    if not dz.get("id") or not title:
        return None
    dzid = str(dz["id"])
    release = session.exec(select(Release).where(Release.deezer_id == dzid)).first()
    if release is None:
        wanted = norm(title)
        release = next(
            (
                r
                for r in session.exec(select(Release).where(Release.artist_id == artist.id)).all()
                if r.deezer_id in (None, dzid) and norm(r.title) == wanted
            ),
            None,
        )
    cover = deezer_image(dz.get("cover_xl") or dz.get("cover_big"))
    if release is None:
        release = Release(
            artist_id=artist.id,
            title=title,
            release_date=dz.get("release_date"),
            release_type=_RECORD_TYPE.get(dz.get("record_type") or "", "album"),
            deezer_id=dzid,
            images=[cover] if cover and not is_placeholder_picture(cover) else [],
        )
    else:
        release.deezer_id = release.deezer_id or dzid
        release.release_date = release.release_date or dz.get("release_date")
        if not release.images and cover and not is_placeholder_picture(cover):
            release.images = [cover]
        release.updated_at = utcnow()
    session.add(release)
    return release


def ingest_track(
    session: Session,
    dz: dict[str, Any],
    *,
    artist: Artist | None,
    release: Release | None,
) -> Recording | None:
    title = (dz.get("title") or "").strip()
    if not dz.get("id") or not title:
        return None
    dzid = str(dz["id"])
    isrc = dz.get("isrc") or None
    recording = session.exec(select(Recording).where(Recording.deezer_id == dzid)).first()
    if recording is None and isrc:
        recording = session.exec(select(Recording).where(Recording.isrc == isrc)).first()
    if recording is None and artist is not None:
        wanted = {norm(title), norm(dz.get("title_short"))} - {""}
        same_title = [
            r
            for r in session.exec(select(Recording).where(Recording.artist_id == artist.id)).all()
            if r.deezer_id in (None, dzid) and norm(r.title) in wanted
        ]
        # Stejné album má přednost (jinak "Creep" ze singlu i z alba splyne).
        same_title.sort(key=lambda r: not (release is not None and r.release_id == release.id))
        recording = same_title[0] if same_title else None

    duration_ms = int(dz["duration"]) * 1000 if dz.get("duration") else None
    if recording is None:
        recording = Recording(
            title=title,
            artist_id=artist.id if artist else None,
            release_id=release.id if release else None,
            duration_ms=duration_ms,
            isrc=isrc,
            track_number=dz.get("track_position"),
            deezer_id=dzid,
        )
    else:
        recording.deezer_id = recording.deezer_id or dzid
        recording.isrc = recording.isrc or isrc
        recording.duration_ms = recording.duration_ms or duration_ms
        recording.artist_id = recording.artist_id or (artist.id if artist else None)
        recording.release_id = recording.release_id or (release.id if release else None)
        recording.track_number = recording.track_number or dz.get("track_position")
        recording.updated_at = utcnow()
    if dz.get("preview") and not (recording.external_refs or {}).get("previewUrl"):
        recording.external_refs = {**(recording.external_refs or {}), "previewUrl": dz["preview"]}
    session.add(recording)
    return recording


def ingest_track_with_context(session: Session, dz: dict[str, Any]) -> Recording | None:
    """Skladba z hledání/playlistu/žebříčku -- nese vnořený `artist` a
    `album`, obojí se upsertne spolu s ní."""
    artist = ingest_artist(session, dz.get("artist") or {})
    release = ingest_album(session, dz.get("album") or {}, artist) if artist is not None else None
    return ingest_track(session, dz, artist=artist, release=release)
