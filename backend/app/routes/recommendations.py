"""REST routy pro doporučení — `/recommendations/*` z docs/openapi.yaml.

Tenká vrstva stejně jako routes/catalog.py: veškerá logika žije v
`app.recommendations.service.RecommendationService`.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from pydantic import BaseModel
from sqlmodel import Session

from app.auth import get_current_user
from app.db import get_session
from app.recommendations.listenbrainz import (
    ListenBrainzClient,
    ListenBrainzPublicClient,
    get_listenbrainz_client,
    get_listenbrainz_public_client,
)
from app.recommendations.service import RecommendationService

recommendations_router = APIRouter(prefix="/recommendations", tags=["recommendations"])



def _lb_user(current: tuple[str, str]) -> str | None:
    """ListenBrainz účet TOHO profilu (Profil › ListenBrainz; admin i z .env).
    Dřív tu byl napevno adminův účet -- jiný profil by dostal jeho doporučení."""
    from app.home.generators import _listenbrainz_user

    return _listenbrainz_user(current[0])


def get_recommendation_service(
    session: Session = Depends(get_session),
    lb_client: ListenBrainzClient = Depends(get_listenbrainz_client),
    lb_public_client: ListenBrainzPublicClient = Depends(get_listenbrainz_public_client),
) -> RecommendationService:
    return RecommendationService(session, lb_client, lb_public_client)


@recommendations_router.get("/discover")
async def discover(
    limit: int = Query(default=20, ge=1, le=100),
    service: RecommendationService = Depends(get_recommendation_service),
    current: tuple[str, str] = Depends(get_current_user),
):
    lb_user = _lb_user(current)
    recordings = await service.discover(lb_user, limit) if lb_user else []
    return [r.model_dump(by_alias=True) for r in recordings]


@recommendations_router.get("/daily-jams")
async def daily_jams(
    service: RecommendationService = Depends(get_recommendation_service),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    playlist = await service.daily_jams(user_id, _lb_user(current))
    return playlist.model_dump(by_alias=True)


@recommendations_router.get("/trending")
async def trending(
    range: str = Query(default="week", pattern="^(week|month|year|all_time)$"),
    limit: int = Query(default=20, ge=1, le=50),
    service: RecommendationService = Depends(get_recommendation_service),
    _current=Depends(get_current_user),
):
    recordings = await service.trending(limit, range)
    return [r.model_dump(by_alias=True) for r in recordings]


@recommendations_router.get("/my-top")
async def my_top(
    range: str = Query(default="month", pattern="^(week|month|year|all_time)$"),
    limit: int = Query(default=20, ge=1, le=50),
    service: RecommendationService = Depends(get_recommendation_service),
    current: tuple[str, str] = Depends(get_current_user),
):
    lb_user = _lb_user(current)
    recordings = await service.my_top_tracks(lb_user, limit, range) if lb_user else []
    return [r.model_dump(by_alias=True) for r in recordings]


@recommendations_router.get("/year-in-review")
async def year_in_review(
    limit: int = Query(default=10, ge=1, le=50),
    service: RecommendationService = Depends(get_recommendation_service),
    current: tuple[str, str] = Depends(get_current_user),
):
    lb_user = _lb_user(current)
    if not lb_user:
        raise HTTPException(status_code=404, detail="Připoj si ListenBrainz účet v Profilu.")
    result = await service.year_in_review(lb_user, limit)
    return result.model_dump(by_alias=True)


@recommendations_router.get("/community")
async def community(
    limit: int = Query(default=20, ge=1, le=50),
    service: RecommendationService = Depends(get_recommendation_service),
    current: tuple[str, str] = Depends(get_current_user),
):
    lb_user = _lb_user(current)
    recordings = await service.community_picks(lb_user, limit) if lb_user else []
    return [r.model_dump(by_alias=True) for r in recordings]


class RadioStationBody(BaseModel):
    kind: str
    id: str


@recommendations_router.post("/radio")
async def radio_station(body: RadioStationBody, current: tuple[str, str] = Depends(get_current_user)):
    """"Přejít na rádio" -- vytvoří (nebo přegeneruje) playlist podobné
    hudby podle skladby/alba/playlistu/interpreta (app/home/radio_station.py)."""
    from app.home.radio_station import StationError, build_station

    try:
        return await build_station(current[0], body.kind, body.id)
    except StationError as exc:
        raise HTTPException(status_code=422, detail=str(exc)) from exc
