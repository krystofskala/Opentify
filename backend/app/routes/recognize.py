"""`POST /recognize` -- Open Shazam (viz app/recognize.py).

Rozpoznaná skladba se založí v katalogu (stejně jako import ze Spotify) a
uloží do "Poslechnout později" se značkou `source="shazam"`.
"""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from sqlmodel import Session

from app import listen_later
from app.auth import get_current_user
from app.db import engine
from app.library.matching import (
    attach_release_if_missing,
    find_or_create_artist,
    find_or_create_recording,
    find_or_create_release,
)
from app.catalog.embedded_art import URL_TEMPLATE, _save_resized, artwork_path
from app.recognize import Match, RecognizeError, fetch_cover, recognize

recognize_router = APIRouter(tags=["recognize"])


def _save(user_id: str, match: Match, cover: bytes | None) -> tuple[dict | None, str | None]:
    cover_url = None
    with Session(engine) as session:
        artist = find_or_create_artist(session, match.artist)
        release = find_or_create_release(session, artist, match.album) if match.album else None
        if release is not None:
            if not release.images and cover and _save_resized(cover, artwork_path(release.id)):
                # Obal na vlastním serveru -- telefon se nikdy nepřipojí k Applu.
                release.images = [URL_TEMPLATE.format(release_id=release.id)]
                session.add(release)
                session.commit()
            cover_url = (release.images or [None])[0]
        recording = find_or_create_recording(session, artist, match.title)
        attach_release_if_missing(session, recording, release)
        if match.isrc and not recording.isrc:
            recording.isrc = match.isrc
            session.add(recording)
            session.commit()
        recording_id = recording.id
    return listen_later.add(user_id, "track", recording_id, None, source="shazam"), cover_url


@recognize_router.post("/recognize")
async def recognize_song(file: UploadFile, current: tuple[str, str] = Depends(get_current_user)):
    raw = await file.read()
    try:
        match = await recognize(raw)
    except RecognizeError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc
    if match is None:
        return {"found": False}
    cover = await fetch_cover(match.cover_url)
    item, cover_url = await asyncio.to_thread(_save, current[0], match, cover)
    return {
        "found": True,
        "title": match.title,
        "artist": match.artist,
        "album": match.album,
        "coverUrl": cover_url,
        "item": item,
    }
