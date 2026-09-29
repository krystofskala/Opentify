"""`/browse` -- stránka Procházet (kategorie nálad a žánrů), viz app/browse.py."""

from __future__ import annotations

import re

from fastapi import APIRouter, HTTPException, Query

from app import browse

browse_router = APIRouter(prefix="/browse", tags=["browse"])

_DEEZER_ID = re.compile(r"^\d{1,20}$")


@browse_router.get("")
def categories():
    return {"categories": browse.list_categories()}


@browse_router.get("/playlists/search")
async def search_playlists(q: str = Query(..., min_length=2, max_length=100)):
    """Playlisty od lidí i redakce Deezeru pro Hledat ("GTA Vice City",
    "Zaklínač soundtrack"...). Jednotlivé rádiové stanice mívají jen ~13
    skladeb, proto nižší spodní hranice než u kategorií."""
    return {"playlists": await browse.search_playlists(q, limit=15, min_tracks=5, max_tracks=3000)}


@browse_router.get("/{category_id}")
async def category(category_id: str):
    c = browse.get_category(category_id)
    if c is None:
        raise HTTPException(status_code=404, detail="kategorie neexistuje")
    return await browse.category_page(c)


@browse_router.get("/{category_id}/mix")
async def category_mix(category_id: str):
    """"Tvůj mix" kategorie podle poslechů -- `playlist: null`, když na mix
    není dost tvých skladeb v téhle náladě/žánru."""
    from app.home import category_mixes as cm

    c = browse.get_category(category_id)
    if c is None:
        raise HTTPException(status_code=404, detail="kategorie neexistuje")
    playlist_id = await cm.build_category_mix(c)
    return {"playlist": cm.playlist_card(playlist_id) if playlist_id else None}


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
