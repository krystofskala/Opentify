"""REST routy pro doporučení — `/recommendations/*` z docs/openapi.yaml.

Tenká vrstva stejně jako routes/catalog.py: veškerá logika žije v
`app.recommendations.service.RecommendationService`.
"""

from __future__ import annotations

import os

from fastapi import APIRouter, Depends, Query
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

# Osobní/single-user systém (viz docs/ARCHITECTURE.md, otevřená otázka #3):
# ListenBrainz uživatelské jméno je serverová konfigurace celé instalace, ne
# odvozené z device JWT identity -- jeden ListenBrainz účet pro server.
LISTENBRAINZ_USERNAME = os.environ.get("LISTENBRAINZ_USERNAME", "demo-user")


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
    _current=Depends(get_current_user),
):
    recordings = await service.discover(LISTENBRAINZ_USERNAME, limit)
    return [r.model_dump(by_alias=True) for r in recordings]


@recommendations_router.get("/daily-jams")
async def daily_jams(
    service: RecommendationService = Depends(get_recommendation_service),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    playlist = await service.daily_jams(user_id, LISTENBRAINZ_USERNAME)
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
    _current=Depends(get_current_user),
):
    recordings = await service.my_top_tracks(LISTENBRAINZ_USERNAME, limit, range)
    return [r.model_dump(by_alias=True) for r in recordings]


@recommendations_router.get("/community")
async def community(
    limit: int = Query(default=20, ge=1, le=50),
    service: RecommendationService = Depends(get_recommendation_service),
    _current=Depends(get_current_user),
):
    recordings = await service.community_picks(LISTENBRAINZ_USERNAME, limit)
    return [r.model_dump(by_alias=True) for r in recordings]
