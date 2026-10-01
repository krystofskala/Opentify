"""Profily a přihlášení zařízení.

- Každé zařízení má dlouhodobý klíč (cookie `opentify_token`, 10 let;
  nativní appka ho posílá jako `Authorization: Bearer`, zkratka iOS jako
  `?t=`). V DB je jen jeho SHA-256.
- Nový profil dostane jednorázovou pozvánku (odkaz `/?join=KÓD`); otevření
  ji vymění za klíč -- jednou na zařízení, pak se nic neřeší.
- Admin (`demo-user` = všechna dosavadní data) se může v Profilu přepnout
  na jiný profil (cookie `opentify_act_as`); ostatní nic takového nevidí.
- `AUTH_MODE=open` (přechod): zařízení bez klíče je admin a klíč si potichu
  vezme samo (`GET /auth/me`). Až má admin klíč na všech svých zařízeních,
  `AUTH_MODE=strict` -- bez platného klíče pak nic (401).
"""

from __future__ import annotations

import hashlib
import os
import secrets
from datetime import datetime, timedelta, timezone

from fastapi import Depends, HTTPException, Request
from sqlmodel import Session, select

from app.db import engine
from app.models import AppUser, AuthToken
from app.utils import utcnow

ADMIN_ID = "demo-user"
TOKEN_COOKIE = "opentify_token"
ACT_AS_COOKIE = "opentify_act_as"


def auth_mode() -> str:
    return os.environ.get("AUTH_MODE", "open").lower()


def hash_secret(value: str) -> str:
    return hashlib.sha256(value.encode()).hexdigest()


def new_secret() -> str:
    return secrets.token_urlsafe(32)


def aware(dt: datetime | None) -> datetime | None:
    """SQLite vrací časy bez zóny -- porovnávat s `utcnow()` jako UTC."""
    if dt is None or dt.tzinfo is not None:
        return dt
    return dt.replace(tzinfo=timezone.utc)


def ensure_admin(session: Session) -> AppUser:
    admin = session.get(AppUser, ADMIN_ID)
    if admin is None:
        admin = AppUser(id=ADMIN_ID, name=os.environ.get("ADMIN_NAME", "Já"), role="admin")
        session.add(admin)
        session.commit()
        session.refresh(admin)
    return admin


def token_from_request(request: Request) -> str | None:
    auth = request.headers.get("authorization") or ""
    if auth.lower().startswith("bearer "):
        return auth[7:].strip() or None
    return request.cookies.get(TOKEN_COOKIE) or request.query_params.get("t") or None


def _user_for_token(session: Session, token: str | None) -> AppUser | None:
    if not token:
        return None
    row = session.exec(select(AuthToken).where(AuthToken.token_hash == hash_secret(token))).first()
    if row is None:
        return None
    now = utcnow()
    if row.last_used_at is None or now - aware(row.last_used_at) > timedelta(hours=6):
        row.last_used_at = now
        session.add(row)
        session.commit()
    return session.get(AppUser, row.user_id)


def _user_for_tailscale(session: Session, login: str, display_name: str | None) -> AppUser:
    """Profil podle Tailscale účtu. Hlavičky `Tailscale-User-*` přidává
    `tailscale serve` (klient je podvrhnout nemůže -- API poslouchá jen na
    127.0.0.1, jediná cesta zvenku vede přes Tailscale). Neznámý účet
    (někdo, komu admin nasdílel server) dostane rovnou vlastní běžný profil
    pojmenovaný podle Tailscale -- žádná pozvánka ani přihlašování."""
    user = session.exec(select(AppUser).where(AppUser.tailscale_login == login)).first()
    if user is None:
        name = (display_name or login.split("@")[0]).strip() or login
        user = AppUser(name=name, role="user", tailscale_login=login)
        session.add(user)
        session.commit()
        session.refresh(user)
    return user


def bind_admin_tailscale() -> None:
    """Tailscale účet admina z `.env` (`TAILSCALE_ADMIN_LOGIN`) -- při
    startu, dřív než první požadavek bez klíče stihne pro admina založit
    nový běžný profil."""
    login = os.environ.get("TAILSCALE_ADMIN_LOGIN", "").strip()
    if not login:
        return
    with Session(engine) as session:
        admin = ensure_admin(session)
        if admin.tailscale_login != login:
            admin.tailscale_login = login
            session.add(admin)
            session.commit()


def resolve_user(request: Request) -> tuple[AppUser | None, AppUser | None]:
    """(přihlášený, za koho jedná) -- admin se může přepnout na jiný profil."""
    with Session(engine) as session:
        user = _user_for_token(session, token_from_request(request))
        login = (request.headers.get("tailscale-user-login") or "").strip()
        if user is None and login:
            user = _user_for_tailscale(session, login, request.headers.get("tailscale-user-name"))
        if user is None and auth_mode() == "open":
            user = ensure_admin(session)
        if user is None:
            return None, None
        acting = user
        act_as = request.headers.get("x-act-as") or request.cookies.get(ACT_AS_COOKIE)
        if user.role == "admin" and act_as and act_as != user.id:
            other = session.get(AppUser, act_as)
            if other is not None:
                acting = other
        session.expunge_all()
        return user, acting


def get_current_user(request: Request) -> tuple[str, str]:
    """(user_id, device_id) -- user_id je profil, za který se jedná."""
    _user, acting = resolve_user(request)
    if acting is None:
        raise HTTPException(status_code=401, detail="Tohle zařízení není přihlášené -- otevři pozvánku.")
    device_id = request.headers.get("x-device-id") or "device"
    return acting.id, device_id


def require_admin(request: Request) -> tuple[str, str]:
    """Správcovské věci (kontrola stažených, sken, mazání sdílených
    souborů) -- jen admin a jen za sebe."""
    user, acting = resolve_user(request)
    if user is None or user.role != "admin":
        raise HTTPException(status_code=403, detail="Tohle může jen správce.")
    return (acting or user).id, request.headers.get("x-device-id") or "device"


CurrentUser = Depends(get_current_user)
