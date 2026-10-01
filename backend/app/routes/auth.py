"""Profily a přihlášení zařízení (viz app/auth.py)."""

from __future__ import annotations

import asyncio
import logging
import os
import secrets
from datetime import timedelta

from fastapi import APIRouter, Depends, HTTPException, Request, Response
from pydantic import BaseModel
from sqlmodel import Session, select

from app.auth import (
    ACT_AS_COOKIE,
    ADMIN_ID,
    TOKEN_COOKIE,
    auth_mode,
    aware,
    ensure_admin,
    hash_secret,
    new_secret,
    require_admin,
    resolve_user,
    token_from_request,
)
from app.db import engine
from app.models import AppUser, AuthToken, InviteCode
from app.utils import utcnow

auth_router = APIRouter(prefix="/auth", tags=["auth"])

_TEN_YEARS = 10 * 365 * 24 * 3600
_INVITE_DAYS = 14


def _set_cookie(response: Response, name: str, value: str) -> None:
    response.set_cookie(name, value, max_age=_TEN_YEARS, httponly=True, secure=True, samesite="lax", path="/")


def _user_out(u: AppUser | None) -> dict | None:
    return None if u is None else {
        "id": u.id,
        "name": u.name,
        "role": u.role,
        "tailscaleLogin": u.tailscale_login,
        "listenbrainzUser": u.listenbrainz_user
        or (os.environ.get("LISTENBRAINZ_USERNAME") if u.id == ADMIN_ID and os.environ.get("LISTENBRAINZ_TOKEN") else None),
    }


def _issue_token(session: Session, user_id: str, label: str | None) -> str:
    token = new_secret()
    session.add(AuthToken(token_hash=hash_secret(token), user_id=user_id, label=label))
    session.commit()
    return token


@auth_router.get("/me")
def me(request: Request, response: Response):
    """Kdo jsem. V přechodném otevřeném režimu si zařízení bez klíče klíč
    admina vezme samo (nic se nezadává)."""
    user, acting = resolve_user(request)
    if user is None:
        return {"user": None, "acting": None, "mode": auth_mode()}
    issued = None
    # Bez Tailscale účtu (ten zařízení pozná sám) a bez klíče: admin si ho
    # v otevřeném režimu vezme potichu.
    tailscale = bool(request.headers.get("tailscale-user-login"))
    if token_from_request(request) is None and not tailscale and auth_mode() == "open" and user.id == ADMIN_ID:
        with Session(engine) as session:
            issued = _issue_token(session, ADMIN_ID, request.headers.get("user-agent", "")[:120])
        # Web: cookie; nativní appka si klíč vezme z těla a posílá ho jako Bearer.
        _set_cookie(response, TOKEN_COOKIE, issued)
    return {"user": _user_out(user), "acting": _user_out(acting), "mode": auth_mode(), "token": issued,
            "tailscaleLogin": request.headers.get("tailscale-user-login")}


class JoinIn(BaseModel):
    code: str


# Společný registrační odkaz: pozvánka s tímhle `user_id` jde použít
# opakovaně a každý, kdo ji otevře, si založí vlastní profil.
SIGNUP = "*signup*"


@auth_router.post("/join")
def join(body: JoinIn, request: Request, response: Response):
    """Pozvánka -> klíč tohoto zařízení (jednou na zařízení)."""
    with Session(engine) as session:
        invite = session.exec(select(InviteCode).where(InviteCode.code_hash == hash_secret(body.code.strip()))).first()
        if invite is not None and invite.user_id == SIGNUP:
            return _signup(session, request, response)
        if invite is None or invite.used_at is not None or aware(invite.expires_at) < utcnow():
            raise HTTPException(status_code=400, detail="Pozvánka neplatí (už použitá nebo prošlá).")
        invite.used_at = utcnow()
        session.add(invite)
        # Pozvánka zároveň spáruje Tailscale účet s profilem -- jeho další
        # zařízení se pak poznají sama, bez pozvánky.
        login = (request.headers.get("tailscale-user-login") or "").strip()
        invited = session.get(AppUser, invite.user_id)
        if login and invited is not None and invited.tailscale_login is None:
            invited.tailscale_login = login
            session.add(invited)
        token = _issue_token(session, invite.user_id, request.headers.get("user-agent", "")[:120])
        user = session.get(AppUser, invite.user_id)
        out = _user_out(user)
    _set_cookie(response, TOKEN_COOKIE, token)
    response.delete_cookie(ACT_AS_COOKIE, path="/")
    return {"user": out, "acting": out, "token": token}


def _signup(session: Session, request: Request, response: Response) -> dict:
    """Registrační odkaz: Tailscale účet, který už profil má, dostane ten
    svůj; nový si založí vlastní (jméno z Tailscale) a hned se s ním spáruje."""
    login = (request.headers.get("tailscale-user-login") or "").strip()
    user = session.exec(select(AppUser).where(AppUser.tailscale_login == login)).first() if login else None
    if user is None:
        name = (request.headers.get("tailscale-user-name") or login.split("@")[0] or "Nový profil").strip()
        user = AppUser(name=name, role="user", tailscale_login=login or None)
        session.add(user)
        session.commit()
        session.refresh(user)
    token = _issue_token(session, user.id, request.headers.get("user-agent", "")[:120])
    out = _user_out(user)
    _set_cookie(response, TOKEN_COOKIE, token)
    response.delete_cookie(ACT_AS_COOKIE, path="/")
    return {"user": out, "acting": out, "token": token}


@auth_router.post("/signup-link")
def signup_link(_admin=Depends(require_admin)):
    """Nový společný registrační odkaz (starý tím přestane platit)."""
    with Session(engine) as session:
        for old in session.exec(select(InviteCode).where(InviteCode.user_id == SIGNUP)).all():
            session.delete(old)
        session.commit()
        code = secrets.token_urlsafe(9)
        session.add(InviteCode(code_hash=hash_secret(code), user_id=SIGNUP, expires_at=utcnow() + timedelta(days=3650)))
        session.commit()
    return {"invite": code}


def _new_invite(session: Session, user_id: str) -> str:
    code = secrets.token_urlsafe(9)
    session.add(InviteCode(code_hash=hash_secret(code), user_id=user_id, expires_at=utcnow() + timedelta(days=_INVITE_DAYS)))
    session.commit()
    return code


@auth_router.get("/users")
def users(_admin=Depends(require_admin)):
    with Session(engine) as session:
        ensure_admin(session)
        rows = session.exec(select(AppUser).order_by(AppUser.created_at)).all()
        devices = {u.id: len(session.exec(select(AuthToken).where(AuthToken.user_id == u.id)).all()) for u in rows}
        return {"items": [{**_user_out(u), "devices": devices[u.id]} for u in rows]}


class NewUserIn(BaseModel):
    name: str


@auth_router.post("/users")
def create_user(body: NewUserIn, _admin=Depends(require_admin)):
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Profil potřebuje jméno.")
    with Session(engine) as session:
        user = AppUser(name=name, role="user")
        session.add(user)
        session.commit()
        session.refresh(user)
        code = _new_invite(session, user.id)
        return {"user": _user_out(user), "invite": code}


@auth_router.post("/users/{user_id}/invite")
def new_invite(user_id: str, _admin=Depends(require_admin)):
    """Nová pozvánka (další zařízení, nebo stará propadla)."""
    with Session(engine) as session:
        if session.get(AppUser, user_id) is None:
            raise HTTPException(status_code=404, detail="Profil neexistuje.")
        return {"invite": _new_invite(session, user_id)}


@auth_router.delete("/users/{user_id}/devices")
def revoke_devices(user_id: str, _admin=Depends(require_admin)):
    """Odhlásit všechna zařízení profilu (třeba ztracený telefon)."""
    if user_id == ADMIN_ID:
        raise HTTPException(status_code=400, detail="Svoje zařízení takhle neodhlašuj.")
    with Session(engine) as session:
        for row in session.exec(select(AuthToken).where(AuthToken.user_id == user_id)).all():
            session.delete(row)
        session.commit()
    return {"userId": user_id, "revoked": True}


class ActAsIn(BaseModel):
    user_id: str | None = None


@auth_router.post("/act-as")
def act_as(body: ActAsIn, response: Response, _admin=Depends(require_admin)):
    """Admin: přepnout se na jiný profil (null = zpět na sebe)."""
    if body.user_id and body.user_id != ADMIN_ID:
        with Session(engine) as session:
            if session.get(AppUser, body.user_id) is None:
                raise HTTPException(status_code=404, detail="Profil neexistuje.")
        _set_cookie(response, ACT_AS_COOKIE, body.user_id)
    else:
        response.delete_cookie(ACT_AS_COOKIE, path="/")
    return {"actingAs": body.user_id or ADMIN_ID}


class ListenBrainzIn(BaseModel):
    token: str


@auth_router.put("/me/listenbrainz")
async def connect_listenbrainz(body: ListenBrainzIn, request: Request):
    """Vlastní ListenBrainz účet profilu, za který se právě jedná: poslechy,
    "právě hraje" a lajky toho profilu pak jdou do JEHO účtu (nikdy do
    adminova). Token se ověří u ListenBrainz a nikdy se nevrací ani neloguje."""
    import httpx

    from app.listens import LB_API

    _user, acting = resolve_user(request)
    if acting is None:
        raise HTTPException(status_code=401, detail="Nepřihlášené zařízení.")
    token = body.token.strip()
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            r = await client.get(f"{LB_API}/1/validate-token", headers={"Authorization": f"Token {token}"})
        data = r.json() if r.status_code == 200 else {}
    except (httpx.HTTPError, ValueError):
        raise HTTPException(status_code=502, detail="ListenBrainz teď neodpovídá, zkus to za chvíli.")
    if not data.get("valid"):
        raise HTTPException(status_code=400, detail="Tenhle token ListenBrainz nezná. Zkopíruj ho z listenbrainz.org/settings.")
    with Session(engine) as session:
        user = session.get(AppUser, acting.id)
        user.listenbrainz_token = token
        user.listenbrainz_user = data.get("user_name")
        session.add(user)
        session.commit()
    from app.listens import _wakeup

    _wakeup.set()  # čekající poslechy profilu odeslat hned
    # Osobní mixy z ListenBrainz (Daily Jams, Objevuj...) hned, ne až zítra.
    asyncio.create_task(_build_listenbrainz_mixes(acting.id))
    return {"listenbrainzUser": data.get("user_name")}


async def _build_listenbrainz_mixes(user_id: str) -> None:
    from app.home import generators as g
    from app.home.service import invalidate_home_cache

    token = g.set_home_user(user_id)
    try:
        count = await g.build_personal_mixes()
        g._save_snapshot("gen:personal:mixes", {"count": count})
    except Exception:  # noqa: BLE001 -- best effort, zítra to zkusí plánovač
        logging.getLogger(__name__).exception("ListenBrainz mixy pro %s selhaly", user_id)
    finally:
        g.reset_home_user(token)
    await invalidate_home_cache()


@auth_router.delete("/me/listenbrainz")
def disconnect_listenbrainz(request: Request):
    _user, acting = resolve_user(request)
    if acting is None:
        raise HTTPException(status_code=401, detail="Nepřihlášené zařízení.")
    with Session(engine) as session:
        user = session.get(AppUser, acting.id)
        user.listenbrainz_token = None
        user.listenbrainz_user = None
        session.add(user)
        session.commit()
    return {"listenbrainzUser": None}
