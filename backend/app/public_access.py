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

import time
from collections import deque

from fastapi import HTTPException, Request

FUNNEL_HEADER = "tailscale-funnel-request"

# Požadavků za minutu z jedné IP. Přehrávač stahuje skladbu po kouscích
# (Range), takže strop je volný; přihlášení má vlastní přísnější limit.
PUBLIC_RATE_PER_MIN = 600
_hits: dict[str, deque[float]] = {}


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


def over_limit(ip: str, now: float | None = None, limit: int | None = None) -> bool:
    """Klouzavé okno 60 s. `True` = tenhle požadavek už je nad limit."""
    now = time.monotonic() if now is None else now
    limit = PUBLIC_RATE_PER_MIN if limit is None else limit
    q = _hits.setdefault(ip, deque())
    while q and now - q[0] > 60:
        q.popleft()
    if len(q) >= limit:
        return True
    q.append(now)
    if len(_hits) > 10_000:  # paměť: zapomenout IP, které už nic neposílají
        for key in [k for k, v in _hits.items() if not v or now - v[-1] > 60]:
            del _hits[key]
    return False
