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
- `AUTH_MODE=login`: jméno + heslo (`POST /auth/login`), klíč zařízení si
  appka pamatuje. Tailscale účet ani otevřený režim nikoho nepřihlásí --
  přes sdílený Tailscale stroj by jinak cizí lidé byli rozlišení jen podle
  účtu, ne podle profilu.
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
from app.public_access import is_public
from app.utils import utcnow

ADMIN_ID = "demo-user"
# Klíč zařízení nepoužitý tak dlouho přestane platit (nové přihlášení pozvánkou).
DEVICE_IDLE_EXPIRY = timedelta(days=90)
TOKEN_COOKIE = "opentify_token"
ACT_AS_COOKIE = "opentify_act_as"


def auth_mode() -> str:
    return os.environ.get("AUTH_MODE", "login").lower()


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
    # Zapomenuté zařízení (starý telefon) se po čase samo odhlásí.
    if now - (aware(row.last_used_at) or aware(row.created_at)) > DEVICE_IDLE_EXPIRY:
        session.delete(row)
        session.commit()
        return None
    if row.last_used_at is None or now - aware(row.last_used_at) > timedelta(hours=6):
        row.last_used_at = now
        session.add(row)
        session.commit()
    return session.get(AppUser, row.user_id)


def purge_stale_tokens() -> int:
    """Smaže klíče zařízení, které se nepoužívají: nikdy nepoužitý klíč
    starší než den (přihlášení v prohlížeči, které si klíč nenechalo, testy,
    starý přechodný režim) a klíč nepoužitý přes `DEVICE_IDLE_EXPIRY`. Dřív
    se mazal jen při použití, takže nepoužité visely v Profilech navždy
    (živě: 10 "zařízení" u jednoho PC). Vrací počet smazaných."""
    now = utcnow()
    removed = 0
    with Session(engine) as session:
        for row in session.exec(select(AuthToken)).all():
            created = aware(row.created_at)
            used = aware(row.last_used_at)
            if (used is None and now - created > timedelta(days=1)) or (used is not None and now - used > DEVICE_IDLE_EXPIRY):
                session.delete(row)
                removed += 1
        session.commit()
    return removed


def _user_for_tailscale(session: Session, login: str) -> AppUser | None:
    """Profil podle Tailscale účtu. Hlavičky `Tailscale-User-*` přidává
    `tailscale serve` (klient je podvrhnout nemůže -- API poslouchá jen na
    127.0.0.1, jediná cesta zvenku vede přes Tailscale). Účet se k profilu
    přiřadí otevřením pozvánky (`/auth/join`); neznámý účet nemá nic."""
    return session.exec(select(AppUser).where(AppUser.tailscale_login == login)).first()


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


def hash_password(password: str) -> str:
    salt = secrets.token_bytes(16)
    digest = hashlib.scrypt(password.encode(), salt=salt, n=2**14, r=8, p=1, dklen=32)
    return f"scrypt${salt.hex()}${digest.hex()}"


def verify_password(password: str, stored: str | None) -> bool:
    if not stored or not stored.startswith("scrypt$"):
        return False
    _, salt_hex, digest_hex = stored.split("$", 2)
    digest = hashlib.scrypt(password.encode(), salt=bytes.fromhex(salt_hex), n=2**14, r=8, p=1, dklen=32)
    return secrets.compare_digest(digest.hex(), digest_hex)


def resolve_user(request: Request) -> tuple[AppUser | None, AppUser | None]:
    """(přihlášený, za koho jedná) -- admin se může přepnout na jiný profil."""
    with Session(engine) as session:
        user = _user_for_token(session, token_from_request(request))
        login = (request.headers.get("tailscale-user-login") or "").strip()
        if auth_mode() == "login":
            login = ""  # jen přihlášení jménem a heslem (klíč zařízení)
        if user is None and login:
            user = _user_for_tailscale(session, login)
            if user is None:
                return None, None  # cizí Tailscale účet bez pozvánky -- nikdy admin
        if user is None and auth_mode() == "open" and not login:
            user = ensure_admin(session)
        if user is None:
            return None, None
        acting = user
        # `act_as` v dotazu: WebSocket z nativní appky hlavičky poslat neumí
        # (Opentify Connect jinak skončil v jiném profilu než HTTP).
        # Jen to, co appka výslovně pošle (hlavička, u WebSocketu dotaz) --
        # dřív i cookie na 10 let: prohlížeč ji posílal sám a část požadavků
        # šla za jiný profil než zbytek (živě: tvoje nastavení, tátova Domů).
        act_as = request.headers.get("x-act-as") or request.query_params.get("act_as")
        # Z veřejného internetu (Funnel) se profily nepřepínají -- správa
        # jen přes Tailscale (app/public_access.py).
        if is_public(request):
            act_as = None
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
    if is_public(request):
        # Správa nikdy z veřejného internetu, ani s klíčem admina.
        raise HTTPException(status_code=403, detail="Správa jde jen přes Tailscale.")
    user, acting = resolve_user(request)
    if user is None or user.role != "admin":
        raise HTTPException(status_code=403, detail="Tohle může jen správce.")
    return (acting or user).id, request.headers.get("x-device-id") or "device"


CurrentUser = Depends(get_current_user)
