"""Sdílení -- univerzální odkaz, který kamarád otevře v jakékoliv hudební
appce (Spotify, Apple Music, YouTube Music, Deezer, Tidal...).

Používá song.link / album.link (Odesli) ve tvaru `https://song.link/d/<Deezer
id>` -- ten nepotřebuje API klíč (jejich API už ho vyžaduje) a stránka sama
nabídne všechny platformy. Deezer id už většina nahrávek/alb má; když ne,
dohledá se (ISRC, pak interpret + název) a uloží. Odkaz nevede na náš
server -- nic z něj (adresa, knihovna) se ven nedostane.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session

from app.catalog.artwork import clean_album_title, primary_artist_name
from app.catalog.deezer import get_deezer_client
from app.db import get_session
from app.models import Artist, Recording, Release

share_router = APIRouter(prefix="/share", tags=["share"])


def _artist_name(session: Session, artist_id: str | None) -> str:
    artist = session.get(Artist, artist_id) if artist_id else None
    return artist.name if artist else ""


@share_router.get("/recordings/{recording_id}")
async def share_recording(recording_id: str, session: Session = Depends(get_session)):
    recording = session.get(Recording, recording_id)
    if recording is None:
        raise HTTPException(status_code=404, detail="skladba nenalezena")
    artist_name = _artist_name(session, recording.artist_id)
    deezer_id = recording.deezer_id
    if not deezer_id:
        client = get_deezer_client()
        track = await client.find_track_by_isrc(recording.isrc) if recording.isrc else None
        if not track or track.get("error") or not track.get("id"):
            track = await client.find_track(primary_artist_name(artist_name), recording.title)
        if not track or not track.get("id"):
            raise HTTPException(status_code=404, detail="skladbu se nepodařilo najít pro sdílení")
        deezer_id = str(track["id"])
        recording.deezer_id = deezer_id
        session.add(recording)
        session.commit()
    return {
        "url": f"https://song.link/d/{deezer_id}",
        "title": recording.title,
        "artistName": artist_name or None,
    }


@share_router.get("/releases/{release_id}")
async def share_release(release_id: str, session: Session = Depends(get_session)):
    release = session.get(Release, release_id)
    if release is None:
        raise HTTPException(status_code=404, detail="album nenalezeno")
    artist_name = _artist_name(session, release.artist_id)
    deezer_id = release.deezer_id
    if not deezer_id:
        client = get_deezer_client()
        wanted = primary_artist_name(artist_name)
        candidates = await client.search_album(wanted, release.title) or []
        if not candidates and clean_album_title(release.title) != release.title:
            candidates = await client.search_album(wanted, clean_album_title(release.title)) or []
        if not candidates:
            raise HTTPException(status_code=404, detail="album se nepodařilo najít pro sdílení")
        deezer_id = str(candidates[0]["id"])
        release.deezer_id = deezer_id
        session.add(release)
        session.commit()
    return {
        "url": f"https://album.link/d/{deezer_id}",
        "title": release.title,
        "artistName": artist_name or None,
    }
