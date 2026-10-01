"""Sdílení -- univerzální odkaz, který kamarád otevře v jakékoliv hudební
appce (Spotify, Apple Music, YouTube Music, Deezer, Tidal...).

Používá song.link / album.link (Odesli) krátké odkazy `https://song.link/<s|i|d>/<id>`
-- nepotřebují API klíč (jejich API už ho vyžaduje). Odesli ale přímé odkazy
dohledá hlavně pro službu, od které se začne; ostatní ukáže jako
"vyhledat". Proto se začíná od toho, co kamarádi používají nejvíc:

1. Spotify (ID přes ListenBrainz labs `spotify-id-from-metadata`, zdarma),
2. Apple Music (iTunes Search API, zdarma),
3. Deezer (ID už většinou máme).

Nalezená ID se ukládají do `external_refs`, podruhé se nic nehledá. Odkaz
nevede na náš server -- nic z něj (adresa, knihovna) se ven nedostane.
"""

from __future__ import annotations

from typing import Any
from urllib.parse import quote

import httpx
from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from app.catalog.identity import is_own_id
from app.catalog.artwork import _normalize, clean_album_title, primary_artist_name
from app.catalog.deezer import get_deezer_client
from app.db import get_session
from app.models import Artist, Recording, Release

share_router = APIRouter(prefix="/share", tags=["share"])

_http = httpx.AsyncClient(timeout=8.0, headers={"User-Agent": "Opentify/0.1 (personal music app)"})


def _artist_name(session: Session, artist_id: str | None) -> str:
    artist = session.get(Artist, artist_id) if artist_id else None
    return artist.name if artist else ""


def _spotify_search(kind: str, title: str, artist: str) -> str:
    """Záloha, když Spotify ID nemáme: vyhledání ve Spotify (otevře appku
    na výsledcích "název interpret"). kind = tracks | albums."""
    return f"https://open.spotify.com/search/{quote(f'{title} {artist}'.strip(), safe='')}/{kind}"


def _same(a: str | None, b: str | None) -> bool:
    na, nb = _normalize(a or ""), _normalize(b or "")
    return bool(na) and bool(nb) and (na == nb or na.startswith(nb) or nb.startswith(na))


async def _spotify_track_id(artist: str, release: str | None, title: str) -> str | None:
    try:
        resp = await _http.post(
            "https://labs.api.listenbrainz.org/spotify-id-from-metadata/json",
            json=[{"artist_name": artist, "release_name": release or "", "track_name": title}],
        )
        rows: list[dict[str, Any]] = resp.json() if resp.status_code == 200 else []
    except (httpx.HTTPError, ValueError):
        return None
    ids = (rows[0].get("spotify_track_ids") if rows else None) or []
    return ids[0] if ids else None


async def _itunes(entity: str, artist: str, title: str) -> dict[str, Any] | None:
    try:
        resp = await _http.get(
            "https://itunes.apple.com/search",
            params={"term": f"{artist} {title}", "entity": entity, "limit": 10, "country": "CZ"},
        )
        results: list[dict[str, Any]] = resp.json().get("results", []) if resp.status_code == 200 else []
    except (httpx.HTTPError, ValueError):
        return None
    name_key = "trackName" if entity == "song" else "collectionName"
    for r in results:
        if _same(r.get("artistName"), artist) and (
            _same(r.get(name_key), title) or _same(clean_album_title(r.get(name_key) or ""), clean_album_title(title))
        ):
            return r
    return None


@share_router.get("/recordings/{recording_id}")
async def share_recording(recording_id: str, session: Session = Depends(get_session)):
    recording = session.get(Recording, recording_id)
    if recording is None:
        raise HTTPException(status_code=404, detail="skladba nenalezena")
    artist_name = _artist_name(session, recording.artist_id)
    if is_own_id(recording.deezer_id):
        # Vlastní nahrávka (tátův Kontrast) -- venku neexistuje, žádné hledání
        # podle jména (našlo by cizí kapelu).
        return {"url": None, "title": recording.title, "artistName": artist_name or None, "spotifySearchUrl": None}
    artist = primary_artist_name(artist_name)
    release = session.get(Release, recording.release_id) if recording.release_id else None
    refs = dict(recording.external_refs or {})
    url: str | None = None

    spotify_id = refs.get("spotifyId") or await _spotify_track_id(artist, release.title if release else None, recording.title)
    if spotify_id:
        refs["spotifyId"] = spotify_id
        url = f"https://song.link/s/{spotify_id}"
    else:
        apple_id = refs.get("appleMusicId")
        if not apple_id:
            hit = await _itunes("song", artist, recording.title)
            apple_id = str(hit["trackId"]) if hit and hit.get("trackId") else None
        if apple_id:
            refs["appleMusicId"] = apple_id
            url = f"https://song.link/i/{apple_id}"

    if url is None:
        deezer_id = recording.deezer_id or refs.get("shareDeezerId")
        if not deezer_id:
            client = get_deezer_client()
            track = await client.find_track_by_isrc(recording.isrc) if recording.isrc else None
            if not track or track.get("error") or not track.get("id"):
                track = await client.find_track(artist, recording.title)
            # Volné hledání umí vrátit cover/živák -- jen ověřená shoda, a jen
            # do external_refs: `deezer_id` je dedup klíč ingestu, cizí id by
            # do téhle nahrávky později slučovalo jiné skladby.
            if (
                track
                and track.get("id")
                and _same((track.get("artist") or {}).get("name"), artist)
                and _same(track.get("title"), recording.title)
            ):
                deezer_id = str(track["id"])
                refs["shareDeezerId"] = deezer_id
        if not deezer_id:
            raise HTTPException(status_code=404, detail="skladbu se nepodařilo najít pro sdílení")
        url = f"https://song.link/d/{deezer_id}"

    if refs != (recording.external_refs or {}):
        recording.external_refs = refs
    session.add(recording)
    session.commit()
    return {
        "url": url,
        "title": recording.title,
        "artistName": artist_name or None,
        # song.link začínající jinde než u Spotify ho často nedohledá.
        "spotifySearchUrl": None if spotify_id else _spotify_search("tracks", recording.title, artist),
    }


@share_router.get("/releases/{release_id}")
async def share_release(release_id: str, session: Session = Depends(get_session)):
    release = session.get(Release, release_id)
    if release is None:
        raise HTTPException(status_code=404, detail="album nenalezeno")
    artist_name = _artist_name(session, release.artist_id)
    if is_own_id(release.deezer_id):
        return {"url": None, "title": release.title, "artistName": artist_name or None, "spotifySearchUrl": None}
    artist = primary_artist_name(artist_name)
    refs = dict(release.external_refs or {})
    url: str | None = None

    # Alba: Apple Music (Spotify ID alba bez Spotify API nedohledáme).
    apple_id = refs.get("appleMusicId")
    if not apple_id:
        hit = await _itunes("album", artist, release.title)
        apple_id = str(hit["collectionId"]) if hit and hit.get("collectionId") else None
    if apple_id:
        refs["appleMusicId"] = apple_id
        url = f"https://album.link/i/{apple_id}"
    else:
        deezer_id = release.deezer_id or refs.get("shareDeezerId")
        if not deezer_id:
            client = get_deezer_client()
            candidates = await client.search_album(artist, release.title) or []
            if not candidates and clean_album_title(release.title) != release.title:
                candidates = await client.search_album(artist, clean_album_title(release.title)) or []
            wanted = clean_album_title(release.title)
            match = next(
                (
                    c
                    for c in candidates
                    if c.get("id")
                    and _same((c.get("artist") or {}).get("name"), artist)
                    and _same(clean_album_title(c.get("title") or ""), wanted)
                ),
                None,
            )
            if match:
                deezer_id = str(match["id"])
                refs["shareDeezerId"] = deezer_id  # ne `deezer_id` -- viz share_recording
        if not deezer_id:
            raise HTTPException(status_code=404, detail="album se nepodařilo najít pro sdílení")
        url = f"https://album.link/d/{deezer_id}"

    if refs != (release.external_refs or {}):
        release.external_refs = refs
    session.add(release)
    session.commit()
    return {
        "url": url,
        "title": release.title,
        "artistName": artist_name or None,
        "spotifySearchUrl": _spotify_search("albums", clean_album_title(release.title), artist),
    }
