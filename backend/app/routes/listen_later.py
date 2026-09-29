"""`/listen-later` -- "Poslechnout později" (viz app/listen_later.py)."""

from __future__ import annotations

import asyncio

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel

from app import listen_later
from app.auth import get_current_user

listen_later_router = APIRouter(prefix="/listen-later", tags=["listen-later"])


class AddBody(BaseModel):
    kind: str
    targetId: str
    note: str | None = None


class UpdateBody(BaseModel):
    note: str | None = None
    restore: bool = False


@listen_later_router.get("")
async def items(current: tuple[str, str] = Depends(get_current_user)):
    return await asyncio.to_thread(listen_later.list_items, current[0])


@listen_later_router.post("")
async def add(body: AddBody, current: tuple[str, str] = Depends(get_current_user)):
    if body.kind not in listen_later.KINDS:
        raise HTTPException(status_code=400, detail="neznámý druh")
    item = await asyncio.to_thread(listen_later.add, current[0], body.kind, body.targetId, body.note)
    if item is None:
        raise HTTPException(status_code=404, detail="nenalezeno")
    return item


@listen_later_router.patch("/{item_id}")
async def update(item_id: str, body: UpdateBody, current: tuple[str, str] = Depends(get_current_user)):
    ok = await asyncio.to_thread(listen_later.update, current[0], item_id, note=body.note, restore=body.restore)
    if not ok:
        raise HTTPException(status_code=404, detail="nenalezeno")
    return {"ok": True}


@listen_later_router.delete("/{item_id}")
async def remove(item_id: str, current: tuple[str, str] = Depends(get_current_user)):
    ok = await asyncio.to_thread(listen_later.remove, current[0], item_id)
    if not ok:
        raise HTTPException(status_code=404, detail="nenalezeno")
    return {"ok": True}
