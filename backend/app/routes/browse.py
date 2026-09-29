"""`/browse` -- stránka Procházet (kategorie nálad a žánrů), viz app/browse.py."""

from __future__ import annotations

import re

from fastapi import APIRouter, HTTPException

from app import browse

browse_router = APIRouter(prefix="/browse", tags=["browse"])

_DEEZER_ID = re.compile(r"^\d{1,20}$")


@browse_router.get("")
def categories():
    return {"categories": browse.list_categories()}


@browse_router.get("/{category_id}")
async def category(category_id: str):
    c = browse.get_category(category_id)
    if c is None:
        raise HTTPException(status_code=404, detail="kategorie neexistuje")
    return await browse.category_page(c)


@browse_router.post("/deezer-playlists/{deezer_id}")
async def open_playlist(deezer_id: str, title: str | None = None):
    """Otevřít Deezer playlist z kategorie -- převezme ho do katalogu a vrátí
    id našeho playlistu (klient pak otevře `/playlists/{id}`)."""
    if not _DEEZER_ID.match(deezer_id):
        raise HTTPException(status_code=400, detail="neplatné id")
    playlist_id = await browse.open_deezer_playlist(deezer_id, title)
    if playlist_id is None:
        raise HTTPException(status_code=502, detail="playlist se nepodařilo načíst")
    return {"playlistId": playlist_id}
