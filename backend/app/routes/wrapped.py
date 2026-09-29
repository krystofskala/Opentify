"""`/wrapped` -- roční a desetiletý souhrn poslechu (viz app/wrapped.py)."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException

from app import wrapped
from app.auth import get_current_user

wrapped_router = APIRouter(prefix="/wrapped", tags=["wrapped"])


@wrapped_router.get("")
async def periods(current: tuple[str, str] = Depends(get_current_user)):
    user_id, _ = current
    return await asyncio.to_thread(wrapped.available_periods, user_id)


@wrapped_router.get("/snippet/{recording_id}")
async def snippet(recording_id: str, _current=Depends(get_current_user)):
    """Úryvek skladby pod obrazovkou Wrappedu (`url`, `startMs`)."""
    found = await wrapped.snippet(recording_id)
    if found is None:
        raise HTTPException(status_code=404, detail="úryvek není k dispozici")
    return found


@wrapped_router.get("/{period}")
async def period(period: str, current: tuple[str, str] = Depends(get_current_user)):
    user_id, _ = current
    stats = await wrapped.period_stats(user_id, period)
    if stats is None:
        raise HTTPException(status_code=404, detail="takové období neexistuje")
    return stats
