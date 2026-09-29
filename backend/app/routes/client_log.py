"""Diagnostika klienta: "černá skříňka" z web/index.html hlásí zamrznutí
appky (hlavní vlákno nereaguje), ztrátu WebGL kontextu a chyby Dartu.

Jen zápis do logu API (`docker compose logs api | Select-String client-log`),
nic se neukládá do DB. Bez přihlášení -- při zamrznutí už appka token
nepřidá; server je dostupný jen přes Tailscale. Velikost omezená.
"""

from __future__ import annotations

import json

from fastapi import APIRouter, Request, Response

client_log_router = APIRouter(tags=["diagnostics"])

MAX_BYTES = 16_000


@client_log_router.post("/client-log", status_code=204)
async def client_log(request: Request) -> Response:
    body = (await request.body())[:MAX_BYTES]
    try:
        data = json.loads(body)
        text = json.dumps(data, ensure_ascii=False)[:MAX_BYTES]
    except ValueError:
        text = body.decode("utf-8", "replace")
    ua = request.headers.get("user-agent", "")[:200]
    # print -> vždy v `docker compose logs`, bez ohledu na nastavení loggingu.
    print(f"client-log ua={ua!r} {text}", flush=True)
    return Response(status_code=204)
