"""Hry -- stránka herních soundtracků (app/games.py)."""

from fastapi import APIRouter, HTTPException

from app import games

games_router = APIRouter(prefix="/games", tags=["games"])


def _cards(page: dict) -> dict:
    """Čerstvé karty mixů a skladatelů (obrázky z DB)."""
    from sqlmodel import Session

    from app import browse
    from app.db import engine
    from app.home.service import _card
    from app.models import Artist, Playlist

    with Session(engine) as session:
        mixes = [
            _card(session, p).model_dump(mode="json", by_alias=True)
            for p in (session.get(Playlist, pid) for pid in (page.get("mixIds") or {}).values())
            if p is not None
        ]
        composers = [browse._artist_card(a) for a in (session.get(Artist, i) for i in page.get("composerIds") or []) if a]
    return {**page, "mixes": mixes, "composers": composers}


@games_router.get("")
async def games_page():
    return _cards(await games.page())


@games_router.get("/series/{series_id}")
async def series(series_id: str):
    out = await games.series_page(series_id)
    if out is None:
        raise HTTPException(status_code=404, detail="série neexistuje")
    return _cards({**out, "mixIds": {"series": out.get("playlistId")} if out.get("playlistId") else {}})


@games_router.get("/{slug}")
async def game(slug: str):
    out = await games.game_page(slug)
    if out is None:
        raise HTTPException(status_code=404, detail="hra neexistuje")
    return out
