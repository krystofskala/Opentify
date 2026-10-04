"""`/browse` -- stránka Procházet (kategorie nálad a žánrů), viz app/browse.py."""

from __future__ import annotations

import re

from app.auth import get_current_user
from fastapi import Depends, APIRouter, HTTPException, Query

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


@browse_router.get("/tag-for-you/{tag:path}")
async def tag_for_you(tag: str, current: tuple[str, str] = Depends(get_current_user)):
    """"Pro tebe · X" stránky stylu -- zvlášť, ať stránka nečeká na skládání."""
    from app import tags

    if not tags.is_style(tag):
        raise HTTPException(status_code=404, detail="tohle není hudební styl")
    return {"forYou": tags.playlist_card(await tags.tag_for_you(tag, current[0]))}


@browse_router.get("/tag-mix/{tag:path}")
async def tag_mix(tag: str, _current: tuple[str, str] = Depends(get_current_user)):
    """Mix stylu "X · nejoblíbenější" -- zvlášť, skládá se nejdéle."""
    from app import tags

    if not tags.is_style(tag):
        raise HTTPException(status_code=404, detail="tohle není hudební styl")
    return {"mix": tags.playlist_card((await tags.tag_mix(tag)).get("playlistId"))}


@browse_router.get("/tag-playlists/{tag:path}")
async def tag_playlists(tag: str, _current: tuple[str, str] = Depends(get_current_user)):
    """Populární playlisty stylu z Deezeru -- zvlášť (první načtení trvá)."""
    from app import tags

    if not tags.is_style(tag):
        raise HTTPException(status_code=404, detail="tohle není hudební styl")
    return {"playlists": await tags.tag_playlists(tag)}


@browse_router.get("/tag/{tag:path}")
async def tag_page(tag: str, current: tuple[str, str] = Depends(get_current_user)):
    """Stránka stylu ze štítku Last.fm (podžánr, štítek interpreta)."""
    from app import tags

    if not tags.is_style(tag):
        raise HTTPException(status_code=404, detail="tohle není hudební styl")
    return await tags.tag_page(tag, current[0])


@browse_router.get("/franchise/{franchise_id}")
async def franchise(franchise_id: str):
    """Franšíza soundtracků jako interpret (app/soundtracks.py)."""
    from app import soundtracks

    out = await soundtracks.franchise(franchise_id)
    if out is None:
        raise HTTPException(status_code=404, detail="franšíza neexistuje")
    return out


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


@browse_router.get("/search-tags")
async def search_tags(q: str, current: tuple[str, str] = Depends(get_current_user)):
    """Žánry a styly pro Hledat › Vše ("blues" -> Blues, Chicago Blues...)."""
    from app import genre_search

    return {"items": await genre_search.search(q, user_id=current[0])}


# Pevné cesty musí být nad `/{category_id}`, jinak by je pohltila
# (/browse/search-tags končilo 404 "kategorie neexistuje").
@browse_router.get("/{category_id}")
async def category(category_id: str):
    c = browse.get_category(category_id)
    if c is None:
        raise HTTPException(status_code=404, detail="kategorie neexistuje")
    return await browse.category_page(c)


@browse_router.get("/{category_id}/mix")
async def category_mix(category_id: str, current: tuple[str, str] = Depends(get_current_user)):
    """"Tvůj mix" kategorie podle poslechů -- `playlist: null`, když na mix
    není dost tvých skladeb v téhle náladě/žánru."""
    from app.home import category_mixes as cm

    c = browse.get_category(category_id)
    if c is None:
        raise HTTPException(status_code=404, detail="kategorie neexistuje")
    # Mix TOHO profilu (dřív vždy adminův -- výchozí home_user).
    from app.home import generators as g

    token = g.set_home_user(current[0])
    try:
        playlist_id = await cm.build_category_mix(c)
    finally:
        g.reset_home_user(token)
    return {"playlist": cm.playlist_card(playlist_id) if playlist_id else None}


@browse_router.get("/{category_id}/for-you")
async def category_for_you(category_id: str, current: tuple[str, str] = Depends(get_current_user)):
    """Stránka žánru › Pro tebe: alba od tvých interpretů, interpreti žánru,
    které ještě neznáš."""
    c = browse.get_category(category_id)
    if c is None or c.group not in ("genre", "mood"):
        raise HTTPException(status_code=404, detail="žánr neexistuje")
    out = await browse.genre_for_you(c, current[0])
    # Tvé podžánry: styly, které posloucháš, a patří pod tenhle žánr.
    from app.home import personal_mixes as pm
    from app.models import HomeSnapshot
    from app.tags import SUBGENRES
    from sqlmodel import Session

    from app.db import engine

    with Session(engine) as session:
        snap = session.get(HomeSnapshot, pm.styles_key(current[0]))
        payload = (snap.payload or {}) if snap else {}
        mine = set(payload.get("all") or payload.get("tags") or [])
    out["yourSubgenres"] = [t for t in SUBGENRES.get(c.id, ()) if t in mine]
    return out
