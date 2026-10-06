"""Schvalování žádostí o stažení (app/download_requests.py).

- `POST /download-requests/{id}/decide?t=&a=approve|deny` -- tlačítko v
  upozornění; BEZ přihlášení, jen s jednorázovým klíčem té jedné žádosti.
- `GET /download-requests`, `POST /download-requests/{id}/approve|deny` --
  správce v appce (jen admin, jen přes Tailscale).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException
from sqlmodel import Session, select

from app import download_requests as dr
from app.auth import require_admin
from app.db import get_session
from app.models import AppUser, DownloadRequest
from app.notify import notify
from app.utils import utcnow

download_requests_router = APIRouter(prefix="/download-requests", tags=["download-requests"])


async def _decide(session: Session, req: DownloadRequest, approve: bool) -> dict:
    if req.status != "pending":
        label = {"approved": "povolená", "denied": "zamítnutá", "expired": "vypršelá"}.get(req.status, req.status)
        notify(f"ℹ️ Žádost už je {label}", req.title, tags=["information_source"], key=f"already:{req.id}", every_s=60)
        return {"ok": True, "status": req.status, "title": req.title, "already": True}
    if dr.expired(req):
        req.status = "expired"
        session.add(req)
        session.commit()
        raise HTTPException(status_code=410, detail="Žádost vypršela.")
    if approve:
        from app.routes.spoken import AcquireIn, acquire_now

        payload = req.payload or {}
        book = await acquire_now(AcquireIn(**payload.get("body", {})), session, req.user_id, payload.get("found"))
        req.book_id = book.get("id")
        req.status = "approved"
    else:
        req.status = "denied"
    req.decided_at = utcnow()
    session.add(req)
    session.commit()
    # Potvrzení na telefon -- ntfy na iPhonu po klepnutí na tlačítko nic
    # neukáže (živě: "nevypadalo, že by se něco stalo").
    if approve:
        notify("✅ Povoleno – stahuje se", req.title, tags=["white_check_mark"])
    else:
        notify("❌ Zamítnuto", req.title, tags=["x"])
    return {"ok": True, "status": req.status, "title": req.title}


@download_requests_router.post("/{req_id}/decide")
async def decide_by_link(req_id: str, t: str = "", a: str = "", session: Session = Depends(get_session)):
    req = session.get(DownloadRequest, req_id)
    # Stejná odpověď pro neexistující žádost i špatný klíč.
    if req is None or not dr.check_token(req, t):
        raise HTTPException(status_code=404, detail="Žádost neexistuje.")
    if a not in ("approve", "deny"):
        raise HTTPException(status_code=422, detail="a=approve|deny")
    return await _decide(session, req, a == "approve")


@download_requests_router.get("")
def list_requests(_admin=Depends(require_admin), session: Session = Depends(get_session)):
    rows = session.exec(select(DownloadRequest).order_by(DownloadRequest.created_at.desc()).limit(50)).all()
    names = {u.id: u.name for u in session.exec(select(AppUser).where(AppUser.id.in_({r.user_id for r in rows}))).all()}  # type: ignore[attr-defined]
    # Čekající nahoře, pak vyřízené (nejnovější první).
    rows = sorted(rows, key=lambda r: r.status != "pending")
    return {"requests": [dr.out(r, names.get(r.user_id)) for r in rows]}


@download_requests_router.post("/{req_id}/approve")
async def approve(req_id: str, _admin=Depends(require_admin), session: Session = Depends(get_session)):
    req = session.get(DownloadRequest, req_id)
    if req is None:
        raise HTTPException(status_code=404, detail="Žádost neexistuje.")
    return await _decide(session, req, True)


@download_requests_router.post("/{req_id}/deny")
async def deny(req_id: str, _admin=Depends(require_admin), session: Session = Depends(get_session)):
    req = session.get(DownloadRequest, req_id)
    if req is None:
        raise HTTPException(status_code=404, detail="Žádost neexistuje.")
    return await _decide(session, req, False)
