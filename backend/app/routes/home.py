"""`GET /home` -- celá obrazovka Domů jedním voláním ze snapshotů v DB."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends

from app.auth import get_current_user
from app.home.service import get_home, run_generators

home_router = APIRouter(prefix="/home", tags=["home"])


@home_router.get("")
async def home(current: tuple[str, str] = Depends(get_current_user)):
    user_id, _device_id = current
    return await get_home(user_id)


@home_router.post("/refresh")
async def refresh_home(force: bool = True, _current=Depends(get_current_user)):
    """Ruční přegenerování (jinak běží samo na pozadí, viz home_refresh_loop).
    Všechny generátory trvají ~3 min -- běží na pozadí, request hned vrátí."""
    asyncio.create_task(run_generators(force=force))
    return {"started": True, "force": force}
