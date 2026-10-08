"""Požadavky z veřejného internetu (Tailscale Funnel).

Funnel pouští lidi bez Tailscale (kamarádi s jinou VPN) na stejnou adresu
jako tailnet. `tailscale serve` takové požadavky označí hlavičkou
`Tailscale-Funnel-Request`; z tailnetu ji nikdo nepošle a kdo si ji
přidá sám, jen si sám zpřísní pravidla. Pro veřejné požadavky platí:

- nic správcovského, ani s klíčem admina (`require_admin` -> 403) a žádné
  přepínání profilů (`act_as`) -- správa jen přes Tailscale,
- bez režimu přihlašování (`AUTH_MODE=login`) vůbec nic: otevřený režim
  na internetu by znamenal přístup pro kohokoli,
- omezení počtu požadavků z jedné IP (zahlcení, stahování katalogu).
"""

from __future__ import annotations

import logging
import time
from collections import deque

from fastapi import HTTPException, Request

logger = logging.getLogger("uvicorn.error.public")

FUNNEL_HEADER = "tailscale-funnel-request"

# Požadavků za minutu z jedné IP. Přehrávač stahuje skladbu po kouscích
# (Range), takže strop je volný; přihlášení má vlastní přísnější limit.
PUBLIC_RATE_PER_MIN = 600
# Obaly mají vlastní, volnější strop: Domů / knihovna při posouvání načte
# stovky obrázků a nad 600/min pak server odmítal i přehrávání (živě 8. 10.,
# kamarád přes Funnel). Diagnostika appky má vlastní malý strop a nikoho
# neupozorňuje -- zaseklá appka ji umí poslat stokrát za minutu.
IMAGE_RATE_PER_MIN = 3000
LOG_RATE_PER_MIN = 60
_hits: dict[str, deque[float]] = {}


def bucket(method: str, path: str) -> str:
    """Do jakého limitu požadavek patří: `img` (obaly), `log` (diagnostika
    appky), jinak `main`."""
    if path == "/api/v1/client-log":
        return "log"
    if method == "GET" and (path.endswith("/cover") or path.startswith("/api/v1/artwork/")):
        return "img"
    return "main"


def limit_for(kind: str) -> int:
    return {"img": IMAGE_RATE_PER_MIN, "log": LOG_RATE_PER_MIN}.get(kind, PUBLIC_RATE_PER_MIN)


def deny_public(request: Request) -> None:
    """Závislost pro věci, které zvenku zatím nejdou (stahování audioknih
    -- desítky GB, limity na uživatele ještě nejsou)."""
    if is_public(request):
        raise HTTPException(status_code=403, detail="Tohle jde zatím jen přes Tailscale.")


def is_public(conn) -> bool:  # Request i WebSocket mají `.headers`
    return bool(conn.headers.get(FUNNEL_HEADER))


def client_ip(conn) -> str:
    forwarded = [p.strip() for p in conn.headers.get("x-forwarded-for", "").split(",") if p.strip()]
    if forwarded:
        return forwarded[-1]
    return conn.client.host if conn.client else "?"


def over_limit(ip: str, now: float | None = None, limit: int | None = None, kind: str = "main") -> bool:
    """Klouzavé okno 60 s. `True` = tenhle požadavek už je nad limit."""
    now = time.monotonic() if now is None else now
    limit = limit_for(kind) if limit is None else limit
    key = ip if kind == "main" else f"{kind}:{ip}"
    if key not in _hits and kind == "main":
        # Přehled, kdo chodí zvenku (a podklad pro upozornění).
        logger.info("funnel: nová veřejná IP %s", ip)
    q = _hits.setdefault(key, deque())
    while q and now - q[0] > 60:
        q.popleft()
    if len(q) >= limit:
        return True
    q.append(now)
    if len(_hits) > 10_000:  # paměť: zapomenout IP, které už nic neposílají
        for key in [k for k, v in _hits.items() if not v or now - v[-1] > 60]:
            del _hits[key]
    return False
