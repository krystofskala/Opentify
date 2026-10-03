"""API Gateway — endpointy podle docs/openapi.yaml se přidávají postupně,
zatím jde o provisioning flow + minimální WS realtime hub."""

from __future__ import annotations

import asyncio
import os
import re

import logging

import httpx
from fastapi import Depends, FastAPI, Request, WebSocket
from fastapi.responses import JSONResponse
from fastapi.middleware.cors import CORSMiddleware

from app.catalog.artwork import artwork_backfill_loop, artwork_progress
from app.catalog.deezer import close_deezer_client
from app.catalog.musicbrainz import close_musicbrainz_client
from app.catalog.wikimedia import close_wikimedia_client
from app.db import init_db
from app.home.service import home_refresh_loop
from app.listens import lb_submit_loop
from app.loudness import backfill_loop
from app.realtime import redis_listener, websocket_endpoint
from app.routes.blends import blends_router
from app.auth import get_current_user
from app.recommendations.listenbrainz import close_listenbrainz_client, close_listenbrainz_public_client
from app.routes.artwork import artwork_router
from app.routes.auth import auth_router
from app.routes.catalog import catalog_router
from app.routes.home import home_router
from app.routes.library import library_router
from app.routes.listens import listens_router
from app.routes.lyrics import lyrics_router
from app.routes.browse import browse_router
from app.routes.games import games_router, movies_router
from app.routes.client_log import client_log_router
from app.routes.listen_later import listen_later_router
from app.routes.wrapped import wrapped_router
from app.routes.radio import radio_router
from app.routes.recognize import recognize_router
from app.routes.share import share_router
from app.routes.playlists import playlists_router
from app.routes.provisioning import jobs_router, tracks_router
from app.routes.recommendations import recommendations_router

def _api_file_log() -> None:
    import logging
    from logging.handlers import RotatingFileHandler
    from pathlib import Path

    try:
        Path("/data/db/logs").mkdir(parents=True, exist_ok=True)
        handler = RotatingFileHandler("/data/db/logs/api.log", maxBytes=5_000_000, backupCount=3, encoding="utf-8")
    except OSError:
        return
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(name)s: %(message)s"))
    handler.setLevel(logging.INFO)
    logging.getLogger("uvicorn.error").addHandler(handler)


_api_file_log()

app = FastAPI(title="Vault API", version="0.1.0")


# Výpadek/limit cizí služby (MusicBrainz 503, Deezer timeout...) není chyba
# serveru: 502/504 s českou hláškou místo holé 500, ať klient ukáže
# "zkus to znovu" a ne "něco se rozbilo".

@app.middleware("http")
async def _log_slow_requests(request, call_next):  # type: ignore[no-untyped-def]
    """Požadavky nad 1,5 s do logu (bez dotazu -- `?t=` je klíč zařízení)."""
    import logging
    import time

    started = time.monotonic()
    response = await call_next(request)
    took = time.monotonic() - started
    if took > 1.5 and not request.url.path.endswith("/stream"):
        logging.getLogger("uvicorn.error.slow").info("pomalé %.1f s %s %s", took, request.method, request.url.path)
    return response

@app.exception_handler(httpx.HTTPStatusError)
async def _upstream_status(_request: Request, exc: httpx.HTTPStatusError) -> JSONResponse:
    logging.getLogger(__name__).warning("upstream %s: HTTP %s", exc.request.url.host, exc.response.status_code)
    return JSONResponse(status_code=502, content={"detail": "Zdroj dat teď neodpovídá, zkus to za chvíli."})


@app.exception_handler(httpx.TimeoutException)
async def _upstream_timeout(_request: Request, exc: httpx.TimeoutException) -> JSONResponse:
    return JSONResponse(status_code=504, content={"detail": "Zdroj dat neodpověděl včas, zkus to za chvíli."})


@app.exception_handler(httpx.TransportError)
async def _upstream_down(_request: Request, exc: httpx.TransportError) -> JSONResponse:
    return JSONResponse(status_code=502, content={"detail": "Zdroj dat je nedostupný, zkus to za chvíli."})

# Povolené originy webu: docker-compose je nastaví na oba Tailscale uzly
# a lokální nginx; "*" zůstává jen jako výchozí pro `flutter run -d chrome`.
_cors_origins = os.environ.get("CORS_ALLOWED_ORIGINS", "*")


class _MaskTokenInLog(logging.Filter):
    """Klíč zařízení v `?t=` (přehrávač na webu/iOS) nesmí skončit v logu."""

    _re = re.compile(r"([?&]t=)[^&\s]+")

    def filter(self, record: logging.LogRecord) -> bool:
        if isinstance(record.args, tuple):
            record.args = tuple(self._re.sub(r"\1***", a) if isinstance(a, str) else a for a in record.args)
        return True


logging.getLogger("uvicorn.access").addFilter(_MaskTokenInLog())
# WebSocket řádky ("WebSocket /ws?...&t=...") loguje uvicorn.error -- maskovat i tam.
logging.getLogger("uvicorn.error").addFilter(_MaskTokenInLog())
app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"] if _cors_origins == "*" else _cors_origins.split(","),
    allow_credentials=False,
    allow_methods=["*"],
    allow_headers=["*"],
)

app.include_router(auth_router, prefix="/api/v1")
app.include_router(tracks_router, prefix="/api/v1", dependencies=[Depends(get_current_user)])
app.include_router(jobs_router, prefix="/api/v1", dependencies=[Depends(get_current_user)])
app.include_router(catalog_router, prefix="/api/v1")
app.include_router(recommendations_router, prefix="/api/v1")
app.include_router(library_router, prefix="/api/v1")
app.include_router(lyrics_router, prefix="/api/v1", dependencies=[Depends(get_current_user)])
app.include_router(playlists_router, prefix="/api/v1")
app.include_router(artwork_router, prefix="/api/v1")
app.include_router(home_router, prefix="/api/v1")
app.include_router(listens_router, prefix="/api/v1")
app.include_router(share_router, prefix="/api/v1", dependencies=[Depends(get_current_user)])
app.include_router(radio_router, prefix="/api/v1")
app.include_router(browse_router, prefix="/api/v1", dependencies=[Depends(get_current_user)])
app.include_router(games_router, prefix="/api/v1", dependencies=[Depends(get_current_user)])
app.include_router(movies_router, prefix="/api/v1", dependencies=[Depends(get_current_user)])
app.include_router(wrapped_router, prefix="/api/v1")
app.include_router(listen_later_router, prefix="/api/v1")
app.include_router(client_log_router, prefix="/api/v1", dependencies=[Depends(get_current_user)])
app.include_router(recognize_router, prefix="/api/v1")
app.include_router(blends_router, prefix="/api/v1")


@app.on_event("startup")
async def on_startup() -> None:
    init_db()
    from app.auth import bind_admin_tailscale

    bind_admin_tailscale()
    # Klasická knihovna: adminovi nic nezmizí (jednorázově, viz entries).
    from app.library.entries import seed_admin_library

    seed_admin_library()
    asyncio.create_task(redis_listener())
    asyncio.create_task(backfill_loop())
    asyncio.create_task(artwork_backfill_loop())
    asyncio.create_task(home_refresh_loop())
    asyncio.create_task(lb_submit_loop())


@app.on_event("shutdown")
async def on_shutdown() -> None:
    await close_musicbrainz_client()
    await close_deezer_client()
    await close_wikimedia_client()
    await close_listenbrainz_client()
    await close_listenbrainz_public_client()


@app.get("/health")
def health() -> dict:
    return {"status": "ok", "artworkBackfill": artwork_progress}


@app.websocket("/ws")
async def ws_route(websocket: WebSocket, user_id: str = "demo-user") -> None:
    # Profil podle klíče zařízení (cookie jde s WS handshakem), ne podle
    # `user_id` z URL -- ten by šel podvrhnout.
    from app.auth import resolve_user

    _user, acting = resolve_user(websocket)  # type: ignore[arg-type]
    if acting is None:
        await websocket.close(code=4401)
        return
    await websocket_endpoint(websocket, acting.id)
