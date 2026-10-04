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


_FEAT_PARENS_RE = re.compile(r"[\(\[]\s*(feat\.?|ft\.?|featuring|with)(?=[\s.])[^\)\]]*[\)\]]", re.IGNORECASE)


def version_key(text: str | None) -> str:
    """Jako `norm`, ale verze v závorce ("Live", "Remix", "Acoustic"...)
    zůstává -- jen "(feat. X)" se zahodí."""
    if not text:
        return ""
    text = _FEAT_PARENS_RE.sub(" ", text)
    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode("ascii").lower()
    return _NON_ALNUM_RE.sub("", text)


def is_placeholder_picture(url: str | None) -> bool:
    return not url or "/artist//" in url or "/cover//" in url


def ingest_artist(session: Session, dz: dict[str, Any]) -> Artist | None:
    name = (dz.get("name") or "").strip()
    if not dz.get("id") or not name:
        return None
    dzid = str(dz["id"])
    picture = deezer_image(dz.get("picture_xl") or dz.get("picture_big"))
    artist = _canonical(session, session.exec(select(Artist).where(Artist.deezer_id == dzid)).first())
    if artist is None:
        candidates = [
            c
            for c in session.exec(select(Artist).where(func.lower(Artist.name) == name.lower())).all()
            if not (c.external_refs or {}).get("mergedInto")
        ]
        # Přednost interpretovi s MBID (knihovna/MusicBrainz), ať se hledání
        # napojí na existující diskografii a přehratelné skladby.
        candidates.sort(key=lambda a: a.mbid is None)
        artist = next((a for a in candidates if a.deezer_id in (None, dzid)), None)
        # Stejné jméno + stejná fotka ještě NENÍ tentýž interpret (fake profil
        # může fotku převzít) -- sloučení až po ověření diskografie, viz
        # `CatalogService._merge_verified_duplicates`.
    changed = artist is None
    if artist is None:
        artist = Artist(name=name, sort_name=name, deezer_id=dzid)
    elif not artist.deezer_id:
        artist.deezer_id = dzid
        changed = True
    has_photo = bool(artist.images) and not is_placeholder_picture(artist.images[0])
    if not has_photo and not is_placeholder_picture(picture):
        artist.images = [picture]
        changed = True
    # Jen když se opravdu něco změnilo -- dřív každé hledání (i z cache)
    # zapisovalo ~20 UPDATE a soupeřilo s workery o zámek databáze.
    if changed:
        artist.updated_at = utcnow()
        session.add(artist)
    return artist


def _canonical(session: Session, artist: Artist | None) -> Artist | None:
    """Sloučený duplikát (`mergedInto`) -> hlavní řádek interpreta."""
    for _ in range(4):
        target = (artist.external_refs or {}).get("mergedInto") if artist else None
        if not target or target == artist.id:
            break
        artist = session.get(Artist, target) or artist
    return artist


# Slova v závorce u alba, která znamenají JINÉ nahrávky ("Limit of Love
# (Commentary)" není "Limit of Love") -- "Deluxe", "Remastered" ne.
_EDITION_VERSION = {
    "commentary", "live", "acoustic", "instrumental", "instrumentals", "remixes", "remix", "karaoke", "demos",
    "demo", "unplugged", "sessions", "session", "orchestral", "piano", "lullaby", "reimagined", "stripped",
}


def album_key(title: str | None) -> str:
    """`norm` + slova verze ze závorky (viz `_EDITION_VERSION`)."""
    words = {
        w for part in _PARENS_RE.findall(title or "")
        for w in _NON_ALNUM_RE.split(unicodedata.normalize("NFKD", part).encode("ascii", "ignore").decode().lower())
        if w in _EDITION_VERSION
    }
    return norm(title) + ("|" + ",".join(sorted(words)) if words else "")


def _type_class(release_type: str | None) -> str | None:
    """Album/kompilace vs singl/EP -- Deezer a MB si "single" a "ep"
    zaměňují, takže se rozlišují jen tyhle dvě skupiny."""
    if release_type in ("album", "compilation"):
        return "long"
    if release_type in ("single", "ep"):
        return "short"
    return None


def release_class(release: Release) -> str | None:
    """Jako `_type_class`, ale u alba ze skladeb (`typeByTracks`, viz
    `CatalogService._fix_release_type`) podle skutečného počtu skladeb --
    Deezer řádky bez record_type mají výchozí "album"."""
    return _type_class((release.external_refs or {}).get("typeByTracks") or release.release_type)


def _year(date: str | None) -> int | None:
    return int(date[:4]) if date and date[:4].isdigit() else None


def _tracklist_count(release: Release) -> int | None:
    refs = release.external_refs or {}
    count = refs.get("tracklistCount") or len(refs.get("tracklistIds") or [])
    return int(count) if count else None


def pick_album_match(
    candidates: list[Release], dz: dict[str, Any], *, track_title: str | None = None
) -> Release | None:
    """Ze stejnojmenných alb interpreta vybere to, které odpovídá Deezer albu.
    Dřív stačil název, a tak se Deezer ALBUM "The Bends" (12 skladeb)
    přilepilo k MB SINGLU "The Bends" (3 skladby) a skladby alba se pak
    zakládaly na singlu. Nesedí-li typ (album vs singl/EP) nebo zjevně počet
    skladeb, kandidát se nebere; jinak přednost shodnému typu, roku a počtu."""
    dz_class = _type_class(_RECORD_TYPE.get(dz.get("record_type") or ""))
    dz_tracks = dz.get("nb_tracks") or None
    dz_year = _year(dz.get("release_date"))
    wanted_track = version_key(track_title) if track_title else ""

    def compatible(r: Release) -> bool:
        if dz_class and release_class(r) not in (None, dz_class):
            return False
        count = _tracklist_count(r)
        # Singl (<= 4) proti albu (>= 8) -- jinak počet nerozhoduje (deluxe edice).
        if dz_tracks and count and min(dz_tracks, count) <= 4 and max(dz_tracks, count) >= 8:
            return False
        return True

    def rank(r: Release) -> tuple:
        titles = {version_key(t) for t in (r.external_refs or {}).get("tracklistTitles") or []}
        count, year = _tracklist_count(r), _year(r.release_date)
        return (
            # Skladba z hledání, která na albu opravdu je.
            not (wanted_track and wanted_track in titles),
            # Typ neznámý (vnořené album u skladby ho nenese) -> spíš album.
            release_class(r) != (dz_class or "long"),
            abs(year - dz_year) if year and dz_year else 99,
            abs(count - dz_tracks) if count and dz_tracks else 999,
        )

    matching = [r for r in candidates if compatible(r)]
    return min(matching, key=rank) if matching else None


def ingest_album(
    session: Session, dz: dict[str, Any], artist: Artist, *, track_title: str | None = None
) -> Release | None:
    title = (dz.get("title") or "").strip()
    if not dz.get("id") or not title:
        return None
    dzid = str(dz["id"])
    release = session.exec(select(Release).where(Release.deezer_id == dzid)).first()
    if release is None:
        wanted = album_key(title)
        release = pick_album_match(
            [
                r
                for r in session.exec(select(Release).where(Release.artist_id == artist.id)).all()
                if r.deezer_id in (None, dzid) and album_key(r.title) == wanted
            ],
            dz,
            track_title=track_title,
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
        # Řádek založený z vnořeného alba skladby (bez record_type) dostal
        # výchozí "album" -- typ z Deezeru ho opraví (MB řádky mají svůj).
        if not release.mbid and release.deezer_id == dzid and dz.get("record_type") in _RECORD_TYPE:
            release.release_type = _RECORD_TYPE[dz["record_type"]]
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
        # Stejné ISRC mívají i jiné verze ("Just Dumb" a "Just Dumb
        # (Commentary)") -- jen se stejným názvem včetně verze.
        from app.download_match import match_label

        recording = next(
            (r for r in session.exec(select(Recording).where(Recording.isrc == isrc)).all() if match_label(r.title, title) is None),
            None,
        )
    if recording is None and artist is not None:
        # Název i s verzí v závorce -- "Heathens" a "Heathens (Live In Mexico
        # City)" jsou různé nahrávky (dřív `norm` závorky zahodil a živá verze
        # se zapsala do řádku studiové). Ignoruje se jen "(feat. ...)".
        wanted = version_key(title)
        same_title = [
            r
            for r in session.exec(select(Recording).where(Recording.artist_id == artist.id)).all()
            if r.deezer_id in (None, dzid) and version_key(r.title) == wanted
        ]
        # Skladby z jiných edic (živé pásky) až nakonec, pak stejné album
        # (jinak "Creep" ze singlu i z alba splyne).
        same_title.sort(key=lambda r: (
            bool((r.external_refs or {}).get("otherEdition")),
            not (release is not None and r.release_id == release.id),
        ))
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
    release = (
        ingest_album(session, dz.get("album") or {}, artist, track_title=dz.get("title"))
        if artist is not None
        else None
    )
    return ingest_track(session, dz, artist=artist, release=release)
