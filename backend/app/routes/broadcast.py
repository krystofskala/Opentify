"""Sdílený stream přes HTTP (app/broadcast.py).

WS je hlavní cesta. HTTP je pro iOS na pozadí, kde WS umře, ale appka, která
hraje, smí posílat požadavky (stejně jako poslechy z kapsy):
  - vysílač: `POST /broadcast/start`, `POST /broadcast/state` (i jako
    heartbeat), `POST /broadcast/stop`; odpověď nese čas serveru (vzorek
    hodin s RTT požadavku), 409 = server vysílání nezná (restart API) ->
    pošli celý start, 410 = převzato / skončilo;
  - posluchač: `GET /broadcast/{sid}/state?after=<clockId>.<gen>.<seq>`
    (long-poll, nejvýš 25 s), 204 = nic nového.
Seznam živých vysílání: `GET /broadcasts` (jen viditelná), kandidáti na
pozvání: `GET /broadcasts/profiles`. Všechno jen přihlášeně.
"""

from __future__ import annotations

import asyncio
import json
from typing import Any

from fastapi import APIRouter, Depends, HTTPException, Request, Response

from app import broadcast as bc
from app.auth import get_current_user

broadcast_router = APIRouter(tags=["broadcast"])

_MAX_BODY = 512_000


async def _body(request: Request) -> dict[str, Any]:
    raw = await request.body()
    if len(raw) > _MAX_BODY:
        raise HTTPException(status_code=413, detail="Zpráva je moc velká.")
    try:
        data = json.loads(raw or b"{}")
    except ValueError:
        raise HTTPException(status_code=400, detail="Neplatný JSON.") from None
    if not isinstance(data, dict):
        raise HTTPException(status_code=400, detail="Neplatná zpráva.")
    return data


def _err(exc: bc.BroadcastError) -> HTTPException:
    return HTTPException(status_code=exc.status, detail=exc.detail)


def _ack(room: bc.Room) -> dict[str, Any]:
    return {
        "sid": room.sid,
        "gen": room.gen,
        "seq": room.seq,
        "clockId": bc.CLOCK_ID,
        "serverMs": bc.hub.server_ms(),
        **bc.hub.listener_info(room),
    }


@broadcast_router.get("/broadcasts")
def list_broadcasts(current: tuple[str, str] = Depends(get_current_user)):
    return {"items": bc.hub.visible_list(current[0])}


@broadcast_router.get("/broadcasts/profiles")
def invite_profiles(current: tuple[str, str] = Depends(get_current_user)):
    return {"items": bc.invite_candidates(current[0])}


@broadcast_router.post("/broadcast/start")
async def start(request: Request, current: tuple[str, str] = Depends(get_current_user)):
    payload = await _body(request)
    user_id, device_id = current
    name = await asyncio.to_thread(bc.profile_name, user_id)
    allowed = await asyncio.to_thread(bc.allowed_invites, user_id)
    try:
        room = await bc.hub.start(user_id, name, payload.get("deviceId") or device_id, payload, allowed)
    except bc.BroadcastError as exc:
        raise _err(exc) from None
    return _ack(room)


@broadcast_router.post("/broadcast/state")
async def state(request: Request, current: tuple[str, str] = Depends(get_current_user)):
    payload = await _body(request)
    try:
        room = await bc.hub.state(current[0], payload)
    except bc.BroadcastError as exc:
        raise _err(exc) from None
    return _ack(room)


@broadcast_router.post("/broadcast/stop")
async def stop(request: Request, current: tuple[str, str] = Depends(get_current_user)):
    payload = await _body(request)
    try:
        await bc.hub.stop(current[0], payload)
    except bc.BroadcastError as exc:
        if exc.status != 410:  # už skončilo -- cíl splněn
            raise _err(exc) from None
    return {"ok": True}


@broadcast_router.get("/broadcast/{sid}/state")
async def poll_state(
    sid: str,
    after: str | None = None,
    wait: float = 25.0,
    current: tuple[str, str] = Depends(get_current_user),
):
    if not bc.valid_id(sid):
        raise HTTPException(status_code=404, detail="Vysílání neexistuje.")
    try:
        out = await bc.hub.poll(current[0], current[1], sid, after, max(0.0, min(wait, 25.0)))
    except bc.BroadcastError as exc:
        raise _err(exc) from None
    if out is None:
        return Response(status_code=204)
    return out
