"""API Gateway — endpointy podle docs/openapi.yaml se přidávají postupně,
zatím jde o provisioning flow + minimální WS realtime hub."""

from __future__ import annotations

import asyncio

from fastapi import FastAPI, WebSocket

from app.catalog.deezer import close_deezer_client
from app.catalog.musicbrainz import close_musicbrainz_client
from app.db import init_db
from app.realtime import redis_listener, websocket_endpoint
from app.recommendations.listenbrainz import close_listenbrainz_client
from app.routes.catalog import catalog_router
from app.routes.provisioning import jobs_router, tracks_router
from app.routes.recommendations import recommendations_router

app = FastAPI(title="Vault API", version="0.1.0")
app.include_router(tracks_router, prefix="/api/v1")
app.include_router(jobs_router, prefix="/api/v1")
app.include_router(catalog_router, prefix="/api/v1")
app.include_router(recommendations_router, prefix="/api/v1")


@app.on_event("startup")
async def on_startup() -> None:
    init_db()
    asyncio.create_task(redis_listener())


@app.on_event("shutdown")
async def on_shutdown() -> None:
    await close_musicbrainz_client()
    await close_deezer_client()
    await close_listenbrainz_client()


@app.get("/health")
def health() -> dict:
    return {"status": "ok"}


@app.websocket("/ws")
async def ws_route(websocket: WebSocket, user_id: str = "demo-user") -> None:
    # TODO: nahradit `user_id` query parametrem ověřením device JWT z
    # `?token=`, viz docs/asyncapi.yaml.
    await websocket_endpoint(websocket, user_id)
