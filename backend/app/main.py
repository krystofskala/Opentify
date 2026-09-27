"""API Gateway — endpointy podle docs/openapi.yaml se přidávají postupně,
zatím jde o provisioning flow + minimální WS realtime hub."""

from __future__ import annotations

import asyncio
import os

from fastapi import FastAPI, WebSocket
from fastapi.middleware.cors import CORSMiddleware

from app.catalog.deezer import close_deezer_client
from app.catalog.musicbrainz import close_musicbrainz_client
from app.db import init_db
from app.realtime import redis_listener, websocket_endpoint
from app.recommendations.listenbrainz import close_listenbrainz_client
from app.routes.catalog import catalog_router
from app.routes.provisioning import jobs_router, tracks_router
from app.routes.recommendations import recommendations_router

app = FastAPI(title="Vault API", version="0.1.0")

# Flutter web klient (client/) běží při vývoji na jiném originu než backend
# (`flutter run -d chrome` má vlastní dev server port), takže bez CORS by
# prohlížeč každý REST request zablokoval. Celý systém žije jen za
# Tailscale/VPN (docs/ARCHITECTURE.md) -- povolit origin natvrdo na
# "*" tady neotevírá nic navíc, co by VPN perimetr nekryl už teď; přesto
# jde přepsat na konkrétní origin(y) přes env, jakmile bude jasné, odkud se
# web klient reálně servíruje.
_cors_origins = os.environ.get("CORS_ALLOWED_ORIGINS", "*")
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if _cors_origins == "*" else _cors_origins.split(","),
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

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
