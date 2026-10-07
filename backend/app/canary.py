"""Hodnoty, které appka nikdy nepoužívá -- když se někde objeví, poplach.

V `.env` na serveru jsou jen jejich otisky (SHA-256, čárkou oddělené):
`REQUEST_DENY_SHA256` (klíče -- hledají se v hlavičkách a v dotazu) a
`LOGIN_DENY_SHA256` (přihlašovací jména, malými písmeny). Kdo takovou
hodnotu použije, musel ji odněkud vyčíst -- v běžném provozu neexistuje.
Hodnoty se nikam nevypisují (ani do upozornění, ani do logu).
"""

from __future__ import annotations

import hashlib
import os
import re

from fastapi import Request

_SPLIT = re.compile(r"[\s,;&=:\"'/?]+")


def _hashes(name: str) -> set[str]:
    return {v.strip().lower() for v in os.environ.get(name, "").split(",") if len(v.strip()) == 64}


def _sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8", "ignore")).hexdigest()


def _alarm(request: Request, what: str) -> None:
    from app import public_access
    from app.notify import notify

    ip = public_access.client_ip(request)
    where = "z internetu" if public_access.is_public(request) else "z tailnetu / zevnitř"
    notify(
        "🚨 PAST: někdo použil falešný údaj",
        f"{what} · {where} · IP {ip} · {request.method} {request.url.path}",
        tags=["rotating_light"], priority=5, key=f"canary:{ip}", every_s=300,
    )


def check_request(request: Request) -> bool:
    """`True` = v hlavičkách nebo dotazu je falešný klíč (a poslal se poplach)."""
    wanted = _hashes("REQUEST_DENY_SHA256")
    if not wanted:
        return False
    text = " ".join([request.url.query or ""] + [v for _k, v in request.headers.items()])
    for part in _SPLIT.split(text):
        if len(part) >= 16 and _sha(part) in wanted:
            _alarm(request, "falešný klíč")
            return True
    return False


def check_username(request: Request, username: str) -> bool:
    wanted = _hashes("LOGIN_DENY_SHA256")
    if wanted and _sha(username.strip().lower()) in wanted:
        _alarm(request, "falešný účet")
        return True
    return False
