"""Obaly alb a fotky interpretů -- jedno místo pro jejich dohledání.

Dřív se obrázky doplňovaly jen líně při otevření detailu alba/interpreta
(`CatalogService._enrich_*_images`), a to jen prvním výsledkem obecného
Deezer `/search` (skladby), bez kontroly, že jde o správného interpreta. Po
naskenování knihovny tak ~80 % alb i interpretů nemělo obrázek vůbec (Domů,
Knihovna i hlavičky byly samé placeholdery).

Zdroje v pořadí spolehlivosti:
  - alba: Cover Art Archive podle MusicBrainz ID (release-group, pak release)
    -> Deezer `/search/album` s kontrolou jména interpreta i alba.
  - interpreti: Deezer `/search/artist` s kontrolou jména (bez Deezer
    placeholderu `/artist//`) -> Wikidata P18 (fotka z Wikimedia Commons)
    přes MusicBrainz url-rels.

Neúspěšné pokusy se zapisují do `external_refs["artworkCheckedAt"]`, aby
backfill smyčka tytéž položky nezkoušela při každém průchodu znovu.
"""

from __future__ import annotations

import asyncio
import difflib
import logging
import re
import unicodedata
from datetime import datetime, timedelta, timezone
from typing import Any

import httpx
from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.fanart import fill_artist_banner, pending_banner_artist_ids
from app.catalog.embedded_art import extract_release_art
from app.catalog.musicbrainz import get_musicbrainz_client
from app.catalog.wikimedia import WIKIMEDIA_USER_AGENT
from app.db import engine
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording, Release
from app.catalog.deezer_ingest import deezer_image

logger = logging.getLogger(__name__)

CAA_BASE = "https://coverartarchive.org"
RECHECK_AFTER = timedelta(days=14)
_CHECKED_KEY = "artworkCheckedAt"

_http = httpx.AsyncClient(timeout=12.0, headers={"User-Agent": WIKIMEDIA_USER_AGENT})


def _normalize(name: str) -> str:
    text = unicodedata.normalize("NFKD", name).encode("ascii", "ignore").decode().casefold()
    text = re.sub(r"\(.*?\)|\[.*?\]", " ", text)
    text = re.sub(r"^the\s+", "", text)
    return re.sub(r"[^a-z0-9]+", "", text)


def primary_artist_name(name: str) -> str:
    """"AURORA;Pomme" / "A feat. B" / "A & B" -> "AURORA"/"A" -- lokální tagy
    často nesou víc interpretů v jednom poli a hledání celého řetězce pak nic
    nenajde."""
    return re.split(r"\s*(?:;|/|,|&|\bfeat\.?|\bft\.?|\bx\b)\s*", name, maxsplit=1, flags=re.IGNORECASE)[0].strip() or name


def _names_match(a: str, b: str) -> bool:
    na, nb = _normalize(a), _normalize(b)
    return bool(na) and bool(nb) and (na == nb or na.startswith(nb) or nb.startswith(na))


async def _caa_front(kind: str, mbid: str) -> str | None:
    if mbid.startswith("own:"):  # vlastní album -- na Cover Art Archive není
        return None
    url = f"{CAA_BASE}/{kind}/{mbid}/front-500"
    try:
        resp = await _http.head(url, follow_redirects=False)
    except httpx.HTTPError:
        return None
    # CAA odpovídá 307 přesměrováním na archive.org, když obal existuje (a
    # posílá `Access-Control-Allow-Origin: *`, takže ho Flutter web načte).
    return url if resp.status_code in (301, 302, 307, 308) else None


# " EP", " - Single", "(Deluxe Edition)", " (2011 Remaster)" ... -- Deezer a
# MusicBrainz tyhle přípony píšou různě, přesné hledání pak nic nenašlo
# ("Black Currents EP" vs. Deezer "Black Currents").
_TITLE_SUFFIX = re.compile(
    r"\s*(?:[-–]\s*)?(?:\(|\[)?\b(?:ep|single|deluxe(?: edition| version)?|expanded edition|"
    r"(?:\d{4}\s*)?remaster(?:ed)?(?:\s*\d{4})?|bonus tracks?(?: version)?)\b(?:\)|\])?\s*$",
    re.IGNORECASE,
)


def clean_album_title(title: str) -> str:
    cleaned = title
    for _ in range(3):
        stripped = _TITLE_SUFFIX.sub("", cleaned).strip()
        if stripped == cleaned or not stripped:
            break
        cleaned = stripped
    return cleaned or title


def _titles_match(a: str, b: str) -> bool:
    return _names_match(a, b) or _names_match(clean_album_title(a), clean_album_title(b))


def _titles_close(a: str, b: str) -> bool:
    """Drobné rozdíly v zápisu ("Black Currents EP" vs. Deezer "Black
    Current EP") -- podobnost očištěných názvů ≥ 85 %."""
    na, nb = _normalize(clean_album_title(a)), _normalize(clean_album_title(b))
    return bool(na) and bool(nb) and difflib.SequenceMatcher(None, na, nb).ratio() >= 0.85


async def resolve_release_cover(
    release_mbid: str | None,
    artist_name: str,
    title: str,
    deezer_id: str | None = None,
    rejected: set[str] | None = None,
) -> str | None:
    """`rejected` -- obaly, které uživatel nahlásil jako špatné ("Špatný
    obal"); hledá se další zdroj."""
    bad = rejected or set()

    def ok(url: str | None) -> bool:
        return bool(url) and url not in bad

    if release_mbid:
        for kind in ("release-group", "release"):
            cover = await _caa_front(kind, release_mbid)
            if ok(cover):
                return cover
    client = get_deezer_client()
    if deezer_id:
        # Deezer id už známe (tracklist ho dohledal) -- obal rovnou.
        album = await client.album(deezer_id)
        if album and (album.get("cover_xl") or album.get("cover_big")):
            cover = deezer_image(album.get("cover_xl") or album.get("cover_big"))
            if ok(cover):
                return cover
    artist = primary_artist_name(artist_name)
    queries = [title]
    if clean_album_title(title) != title:
        queries.append(clean_album_title(title))
    for query in queries:
        try:
            albums = await client.search_album(artist, query)
        except Exception:  # noqa: BLE001 - best-effort
            continue
        for album in albums:
            if _titles_match(album.get("title", ""), title) and _names_match(
                (album.get("artist") or {}).get("name", ""), artist
            ):
                cover = deezer_image(album.get("cover_xl") or album.get("cover_big"))
                if ok(cover):
                    return cover
    # Poslední pokus: volné hledání a tolerantní shoda názvu (překlepy, "s").
    try:
        loose = await client.search_typed("album", f"{artist} {clean_album_title(title)}", 5) or []
    except Exception:  # noqa: BLE001
        loose = []
    for album in loose:
        if _titles_close(album.get("title", ""), title) and _names_match(
            (album.get("artist") or {}).get("name", ""), artist
        ):
            cover = deezer_image(album.get("cover_xl") or album.get("cover_big"))
            if ok(cover):
                return cover
    return None


def _is_deezer_placeholder(url: str | None) -> bool:
    return not url or "/artist//" in url or "/images/artist/" not in url


async def _wikidata_image(artist_mbid: str) -> str | None:
    try:
        mb_artist = await get_musicbrainz_client().get_artist(artist_mbid)
    except Exception:  # noqa: BLE001
        return None
    qid = None
    for rel in mb_artist.get("relations") or []:
        if rel.get("type") == "wikidata":
            candidate = ((rel.get("url") or {}).get("resource") or "").rsplit("/", 1)[-1]
            if candidate.startswith("Q"):
                qid = candidate
                break
    if qid is None:
        return None
    try:
        resp = await _http.get(
            "https://www.wikidata.org/w/api.php",
            params={"action": "wbgetentities", "ids": qid, "props": "claims", "format": "json"},
        )
        claims = resp.json()["entities"][qid]["claims"]
        filename = claims["P18"][0]["mainsnak"]["datavalue"]["value"]
    except Exception:  # noqa: BLE001 - P18 chybí/neočekávaný tvar
        return None
    try:
        # `Special:FilePath` jen přesměrovává -- uložíme finální
        # upload.wikimedia.org URL, která posílá CORS hlavičky.
        img = await _http.head(
            f"https://commons.wikimedia.org/wiki/Special:FilePath/{filename}",
            params={"width": 1200},
            follow_redirects=True,
        )
    except httpx.HTTPError:
        return None
    return str(img.url) if img.status_code == 200 else None


async def resolve_artist_image(
    name: str, artist_mbid: str | None, *, allow_musicbrainz: bool = True, deezer_id: str | None = None
) -> str | None:
    # Známe-li Deezer id, fotka přesně toho interpreta -- hledání podle jména
    # dalo Chrisi Thileovi fotku Meshell Ndegeocello.
    if deezer_id:
        try:
            dz = await get_deezer_client().artist(deezer_id)
        except Exception:  # noqa: BLE001
            dz = None
        picture = deezer_image((dz or {}).get("picture_xl") or (dz or {}).get("picture_big"))
        if picture and not _is_deezer_placeholder(picture):
            return picture
        if dz:
            # Interpret na Deezeru bez fotky -- hledání podle jména by vrátilo
            # cizího jmenovce; jen Wikidata (podle MBID) je pořád ten pravý.
            return await _wikidata_image(artist_mbid) if artist_mbid and allow_musicbrainz else None
    wanted = primary_artist_name(name)
    try:
        artists = await get_deezer_client().search_artist(wanted, trust_name=False)
    except Exception:  # noqa: BLE001
        artists = []
    for candidate in artists:
        picture = deezer_image(candidate.get("picture_xl") or candidate.get("picture_big"))
        if _names_match(candidate.get("name", ""), wanted) and not _is_deezer_placeholder(picture):
            return picture
    # Wikidata fallback potřebuje MusicBrainz (1 req/s sdílený s hledáním) --
    # jen na vyžádání (otevřený detail), nikdy z backfill smyčky, jinak ta
    # smyčka zabere MB frontu a uživatelské požadavky čekají.
    if artist_mbid and allow_musicbrainz:
        return await _wikidata_image(artist_mbid)
    return None


def _recently_checked(refs: dict[str, Any]) -> bool:
    stamp = refs.get(_CHECKED_KEY)
    if not stamp:
        return False
    try:
        return datetime.now(timezone.utc) - datetime.fromisoformat(stamp) < RECHECK_AFTER
    except ValueError:
        return False


def _mark_checked(refs: dict[str, Any]) -> dict[str, Any]:
    return {**refs, _CHECKED_KEY: datetime.now(timezone.utc).isoformat()}


async def fill_release(release_id: str, *, force: bool = False) -> bool:
    with Session(engine) as session:
        release = session.get(Release, release_id)
        if release is None or release.images or (not force and _recently_checked(release.external_refs)):
            return False
        artist = session.get(Artist, release.artist_id)
        mbid, title, artist_name = release.mbid, release.title, artist.name if artist else ""
        deezer_id = release.deezer_id
        rejected = set((release.external_refs or {}).get("rejectedCovers") or [])

    # Album z vlastních souborů (bez id): obal vložený v souborech má
    # přednost; online jen podle interpreta i názvu alba zároveň.
    own = (not mbid and not deezer_id) or (mbid or "").startswith("own:")
    cover = await asyncio.to_thread(extract_release_art, release_id) if own else None
    if cover is None and not (mbid or "").startswith("own:"):
        # Vlastní album (own:) online nehledat -- našlo by stejnojmenné cizí.
        cover = await resolve_release_cover(mbid, artist_name, title, deezer_id, rejected)
    if cover in rejected:
        cover = None
    if cover is None:
        # Poslední záchrana jen pro alba z knihovny: obal vložený v lokálních
        # souborech (u alb bez lokálních souborů vrátí rovnou `None`).
        cover = await asyncio.to_thread(extract_release_art, release_id)
    if cover in rejected:
        cover = None

    with Session(engine) as session:
        release = session.get(Release, release_id)
        if release is None or release.images:
            return False
        if cover:
            release.images = [cover]
        release.external_refs = _mark_checked(release.external_refs or {})
        session.add(release)
        session.commit()
    return cover is not None


async def fill_artist(artist_id: str, *, force: bool = False) -> bool:
    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None:
            return False
        has_real_image = bool(artist.images) and not _is_deezer_placeholder(artist.images[0])
        if has_real_image or (not force and _recently_checked(artist.external_refs)):
            return False
        name, mbid, deezer_id = artist.name, artist.mbid, artist.deezer_id

    from app.catalog.identity import is_own_id, local_only_artist

    if is_own_id(mbid):
        return False  # vlastní interpret (tátův Kontrast): fotku nikdy podle jména
    if not mbid and await asyncio.to_thread(local_only_artist, name) is not None:
        return False  # vlastní hudba: fotku ne podle jména (kapel stejného jména je víc)
    picture = await resolve_artist_image(name, mbid, allow_musicbrainz=force, deezer_id=deezer_id)

    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None:
            return False
        if picture:
            artist.images = [picture]
        elif artist.images and _is_deezer_placeholder(artist.images[0]):
            artist.images = []
        artist.external_refs = _mark_checked(artist.external_refs or {})
        session.add(artist)
        session.commit()
    return picture is not None


def _pending(limit: int) -> tuple[list[str], list[str], list[str]]:
    """Nejdřív to, co je v knihovně (má přehratelnou skladbu) -- to uživatel
    vidí na Domů/Knihovně, zbytek katalogu (výsledky hledání, diskografie)
    až potom."""
    with Session(engine) as session:
        library_release_ids = set(
            session.exec(
                select(Recording.release_id)
                .join(MediaAsset, MediaAsset.recording_id == Recording.id)
                .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
            ).all()
        )
        library_artist_ids = set(
            session.exec(
                select(Recording.artist_id)
                .join(MediaAsset, MediaAsset.recording_id == Recording.id)
                .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
            ).all()
        )
        releases = [
            r
            for r in session.exec(select(Release)).all()
            if not r.images and not _recently_checked(r.external_refs or {})
        ]
        artists = [
            a
            for a in session.exec(select(Artist)).all()
            if (not a.images or _is_deezer_placeholder(a.images[0])) and not _recently_checked(a.external_refs or {})
        ]
        banner_ids = pending_banner_artist_ids(session, library_artist_ids, limit)
    releases.sort(key=lambda r: r.id not in library_release_ids)
    artists.sort(key=lambda a: a.id not in library_artist_ids)
    return [r.id for r in releases[:limit]], [a.id for a in artists[:limit]], banner_ids


artwork_progress: dict[str, int | bool] = {"running": False, "filled": 0, "checked": 0, "embedded": 0}

_EMBEDDED_CHECKED_KEY = "embeddedArtCheckedAt"


def _embedded_pass() -> int:
    """Jednorázový průchod přes alba z knihovny, která online zdroje už
    dřív zkontrolovaly bez výsledku (vložené obaly tehdy ještě nebyly
    fallback) -- zkusí vytáhnout obal z lokálních souborů. Značka v
    `external_refs` zajistí, že se album zkouší jen jednou."""
    with Session(engine) as session:
        library_release_ids = set(
            session.exec(
                select(Recording.release_id)
                .join(MediaAsset, MediaAsset.recording_id == Recording.id)
                .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
            ).all()
        )
        candidates = [
            r.id
            for r in session.exec(select(Release)).all()
            if r.id in library_release_ids and not r.images and not (r.external_refs or {}).get(_EMBEDDED_CHECKED_KEY)
        ]
    filled = 0
    for release_id in candidates:
        url = extract_release_art(release_id)
        with Session(engine) as session:
            release = session.get(Release, release_id)
            if release is None:
                continue
            if url and not release.images:
                release.images = [url]
                filled += 1
            release.external_refs = {
                **(release.external_refs or {}),
                _EMBEDDED_CHECKED_KEY: datetime.now(timezone.utc).isoformat(),
            }
            session.add(release)
            session.commit()
    return filled


async def artwork_backfill_loop(idle_interval_s: float = 300.0, pause_s: float = 0.3) -> None:
    """Na pozadí po celou dobu běhu API: postupně (jedna položka naráz, s
    pauzou) doplní obrázky všem albům a interpretům, co je nemají -- knihovna
    přednostně. Střídá alba a interprety, ať se obojí plní souběžně."""
    await asyncio.sleep(5)
    try:
        artwork_progress["embedded"] = await asyncio.to_thread(_embedded_pass)
        logger.info("artwork: vložené obaly doplněny u %s alb", artwork_progress["embedded"])
    except Exception:  # noqa: BLE001
        logger.exception("artwork: průchod vloženými obaly selhal")
    while True:
        try:
            release_ids, artist_ids, banner_ids = await asyncio.to_thread(_pending, 40)
            if not release_ids and not artist_ids and not banner_ids:
                artwork_progress["running"] = False
                await asyncio.sleep(idle_interval_s)
                continue
            artwork_progress["running"] = True
            for i in range(max(len(release_ids), len(artist_ids), len(banner_ids))):
                if i < len(release_ids):
                    artwork_progress["filled"] = int(artwork_progress["filled"]) + int(await fill_release(release_ids[i]))
                    artwork_progress["checked"] = int(artwork_progress["checked"]) + 1
                if i < len(artist_ids):
                    artwork_progress["filled"] = int(artwork_progress["filled"]) + int(await fill_artist(artist_ids[i]))
                    artwork_progress["checked"] = int(artwork_progress["checked"]) + 1
                if i < len(banner_ids):
                    artwork_progress["banners"] = int(artwork_progress.get("banners", 0)) + int(
                        await fill_artist_banner(banner_ids[i])
                    )
                await asyncio.sleep(pause_s)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - smyčka nesmí umřít kvůli jedné položce
            logger.exception("artwork backfill: chyba v dávce, zkusím za chvíli znovu")
            await asyncio.sleep(60)
