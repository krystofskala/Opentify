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
        stations = [
            _card(session, p).model_dump(mode="json", by_alias=True)
            for p in (session.get(Playlist, pid) for pid in page.get("stationIds") or [])
            if p is not None
        ]
    return {**page, "mixes": mixes, "composers": composers, "stations": stations}


@games_router.get("")
async def games_page():
    return _cards(await games.page())


@games_router.get("/series/{series_id}")
async def series(series_id: str):
    from app import works

    if works.is_qid(series_id):
        out = await games.work_series_page(series_id)
        if out is None:
            raise HTTPException(status_code=404, detail="série neexistuje")
        return _cards({**out, "mixIds": {"series": out.get("playlistId")} if out.get("playlistId") else {}})
    out = await games.series_page(series_id)
    if out is None:
        raise HTTPException(status_code=404, detail="série neexistuje")
    return _cards({**out, "mixIds": {"series": out.get("playlistId")} if out.get("playlistId") else {}})


@games_router.get("/{slug}")
async def game(slug: str):
    from app import works

    if works.is_qid(slug):
        out = await games.work_page(slug)
        if out is None:
            raise HTTPException(status_code=404, detail="dílo neexistuje")
        return _cards(out)
    out = await games.game_page(slug)
    if out is None:
        raise HTTPException(status_code=404, detail="hra neexistuje")
    return _cards(out)


# Filmy a seriály -- stejná stránka nad jiným katalogem (app/movies.py).
movies_router = APIRouter(prefix="/movies", tags=["movies"])


@movies_router.get("")
async def movies_page():
    from app.movies import MOVIES_CATALOG

    return _cards(await games.page(MOVIES_CATALOG))


@movies_router.get("/series/{series_id}")
async def movie_series(series_id: str):
    from app import works
    from app.movies import MOVIES_CATALOG

    if works.is_qid(series_id):
        return await series(series_id)

    out = await games.series_page(series_id, MOVIES_CATALOG)
    if out is None:
        raise HTTPException(status_code=404, detail="série neexistuje")
    return _cards({**out, "mixIds": {"series": out.get("playlistId")} if out.get("playlistId") else {}})


@movies_router.get("/{slug}")
async def movie(slug: str):
    from app import works
    from app.movies import MOVIES_CATALOG

    if works.is_qid(slug):
        return await game(slug)

    out = await games.game_page(slug, MOVIES_CATALOG)
    if out is None:
        raise HTTPException(status_code=404, detail="film neexistuje")
    return _cards(out)


# Hledání filmů, seriálů a her (Wikidata) -- Hledat › Vše.
works_router = APIRouter(prefix="/works", tags=["works"])


@works_router.get("/search")
async def works_search(q: str):
    return {"items": await games.work_search(q)}
