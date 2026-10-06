"""Diagnostika klienta: "černá skříňka" z web/index.html hlásí zamrznutí
appky (hlavní vlákno nereaguje), ztrátu WebGL kontextu a chyby Dartu.

Zápis do logu API (`docker compose logs api | Select-String client-log`)
a do souboru `/data/db/client-log.jsonl` (log kontejneru zmizí s každým
nasazením; soubor má nejvýš ~5 MB, pak se starší polovina zahodí), nic
do DB. Chráněné přihlášením (main.py; web posílá cookie
i při zamrznutí). Tělo se čte jen do limitu a vypisuje na jeden řádek.
"""

from __future__ import annotations

import asyncio
import json
import os
from datetime import UTC, datetime
from pathlib import Path

from fastapi import APIRouter, Request, Response

client_log_router = APIRouter(tags=["diagnostics"])

MAX_BYTES = 16_000
LOG_FILE = Path(os.environ.get("CLIENT_LOG_FILE", "/data/db/client-log.jsonl"))
MAX_FILE_BYTES = 5_000_000


def _append(line: str) -> None:
    try:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        if LOG_FILE.exists() and LOG_FILE.stat().st_size > MAX_FILE_BYTES:
            # Novější polovina zůstává (od začátku celého řádku).
            data = LOG_FILE.read_bytes()
            keep = data[len(data) // 2 :]
            LOG_FILE.write_bytes(keep[keep.find(b"\n") + 1 :])
        with LOG_FILE.open("a", encoding="utf-8") as f:
            f.write(line + "\n")
    except OSError:
        pass  # diagnostika nikdy nesmí shodit request


@client_log_router.post("/client-log", status_code=204)
async def client_log(request: Request) -> Response:
    chunks: list[bytes] = []
    size = 0
    async for chunk in request.stream():
        chunks.append(chunk)
        size += len(chunk)
        if size >= MAX_BYTES:
            break  # zbytek se nečte
    body = b"".join(chunks)[:MAX_BYTES]
    try:
        data = json.loads(body)
        text = json.dumps(data, ensure_ascii=False)[:MAX_BYTES]
    except ValueError:
        # Jeden řádek -- žádné podvržené řádky v logu.
        text = repr(body.decode("utf-8", "replace"))
    ua = request.headers.get("user-agent", "")[:200]
    # print -> vždy v `docker compose logs`, bez ohledu na nastavení loggingu.
    print(f"client-log ua={ua!r} {text}", flush=True)
    record = json.dumps({"at": datetime.now(UTC).isoformat(timespec="seconds"), "ua": ua, "body": text}, ensure_ascii=False)
    await asyncio.to_thread(_append, record)
    return Response(status_code=204)
