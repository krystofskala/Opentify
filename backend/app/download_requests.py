"""Žádosti o stažení, které musí schválit správce.

Žádost uloží vše potřebné ke stažení (i výsledek hledání ze Soulseeku, který
jinak za hodinu vyprší) a pošle správci upozornění s tlačítky Povolit /
Zamítnout. Tlačítka volají `POST /download-requests/{id}/decide?t=…&a=…` s
jednorázovým tajným klíčem jen pro tuhle žádost (v DB jen otisk, platí
`VALID_H` hodin) -- fungují i bez Tailscale, ale nic jiného neumí.
"""

from __future__ import annotations

import hmac
from datetime import timedelta

from sqlmodel import Session

from app.auth import aware, hash_secret, new_secret
from app.db import engine
from app.models import AppUser, DownloadRequest
from app.notify import notify
from app.utils import utcnow

VALID_H = 24
GB = 1024**3


def create(user_id: str, body: dict, found: dict | None, size: int | None, reason: str, base_url: str) -> dict:
    token = new_secret()
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        title = (body.get("folder") or body.get("title") or "?")[:300]
        req = DownloadRequest(
            user_id=user_id,
            title=title,
            size_bytes=size,
            reason=reason,
            payload={"body": body, "found": found},
            token_hash=hash_secret(token),
        )
        session.add(req)
        session.commit()
        session.refresh(req)
        req_id, who = req.id, (user.name if user else user_id[:8])
    size_txt = f"{size / GB:.1f} GB" if size else "velikost neznámá"
    actions = []
    if base_url:
        link = f"{base_url}/api/v1/download-requests/{req_id}/decide?t={token}"
        actions = [
            {"action": "http", "label": "Povolit", "url": link + "&a=approve", "method": "POST", "clear": True},
            {"action": "http", "label": "Zamítnout", "url": link + "&a=deny", "method": "POST", "clear": True},
        ]
    notify(
        f"📚 {who} chce stáhnout audioknihu",
        f"{title}\n{size_txt} · {reason}",
        tags=["books"], priority=4, actions=actions,
    )
    return {"status": "awaiting_approval", "requestId": req_id, "title": title, "reason": reason}


def check_token(req: DownloadRequest, token: str) -> bool:
    return hmac.compare_digest(req.token_hash, hash_secret(token or ""))


def expired(req: DownloadRequest) -> bool:
    return utcnow() - aware(req.created_at) > timedelta(hours=VALID_H)


def out(req: DownloadRequest) -> dict:
    return {
        "id": req.id,
        "userId": req.user_id,
        "title": req.title,
        "sizeBytes": req.size_bytes,
        "reason": req.reason,
        "status": req.status,
        "createdAt": req.created_at.isoformat() if req.created_at else None,
        "bookId": req.book_id,
    }
