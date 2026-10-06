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

from app.redis_bus import get_redis
from app.auth import (
    ACT_AS_COOKIE,
    ADMIN_ID,
    TOKEN_COOKIE,
    auth_mode,
    aware,
    ensure_admin,
    get_current_user,
    hash_password,
    hash_secret,
    new_secret,
    require_admin,
    resolve_user,
    token_from_request,
    verify_password,
)
from app.db import engine
from app.models import AppUser, AuthToken, InviteCode, PairCode
from app.notify import notify
from app.public_access import client_ip, is_public
from app.utils import utcnow

auth_router = APIRouter(prefix="/auth", tags=["auth"])

_TEN_YEARS = 10 * 365 * 24 * 3600
_INVITE_DAYS = 14

# --- Kód zařízení (druhý faktor k jménu a heslu) ---------------------------
# Nové zařízení se přihlásí jen s jednorázovým kódem, který vytvoří admin
# (pro profil) nebo člověk sám na už přihlášeném zařízení. Uhodnuté nebo
# uniklé heslo samo nestačí. Přihlášená zařízení zůstávají (klíč v DB).
# Vypnout jde `LOGIN_DEVICE_CODE=0` (jen pro nouzi; výchozí zapnuto).
_PAIR_HOURS = 24
_PAIR_ALPHABET = "ABCDEFGHJKMNPQRSTUVWXYZ23456789"  # bez 0/O, 1/I/L


def pair_code_required() -> bool:
    return os.environ.get("LOGIN_DEVICE_CODE", "1").strip().lower() not in ("0", "false", "no", "off")


def _norm_pair(code: str | None) -> str:
    return "".join(ch for ch in (code or "").upper() if ch.isalnum())


def new_pair_code(session: Session, user_id: str, created_by: str | None) -> tuple[str, object]:
    """Nový kód (`ABCD-EFGH`) pro profil; starší nepoužité kódy profilu
    přestanou platit (platí vždy jen ten poslední)."""
    for old in session.exec(select(PairCode).where(PairCode.user_id == user_id, PairCode.used_at.is_(None))).all():  # type: ignore[union-attr]
        session.delete(old)
    raw = "".join(secrets.choice(_PAIR_ALPHABET) for _ in range(8))
    expires = utcnow() + timedelta(hours=_PAIR_HOURS)
    session.add(PairCode(code_hash=hash_secret(raw), user_id=user_id, created_by=created_by, expires_at=expires))
    session.commit()
    return f"{raw[:4]}-{raw[4:]}", expires


def _take_pair_code(session: Session, user_id: str, code: str | None) -> bool:
    """Platný nepoužitý kód TOHOTO profilu -> spotřebovat."""
    norm = _norm_pair(code)
    if len(norm) != 8:
        return False
    row = session.exec(select(PairCode).where(PairCode.code_hash == hash_secret(norm))).first()
    if row is None or row.user_id != user_id or row.used_at is not None or aware(row.expires_at) < utcnow():
        return False
    row.used_at = utcnow()
    session.add(row)
    return True


def _set_cookie(response: Response, name: str, value: str) -> None:
    response.set_cookie(name, value, max_age=_TEN_YEARS, httponly=True, secure=True, samesite="lax", path="/")


def _user_out(u: AppUser | None) -> dict | None:
    return None if u is None else {
        "id": u.id,
        "name": u.name,
        "role": u.role,
        "tailscaleLogin": u.tailscale_login,
        "username": u.username,
        "hasPassword": u.password_hash is not None,
        "lastfmUser": u.lastfm_user,
        "listenbrainzUser": u.listenbrainz_user
        or (os.environ.get("LISTENBRAINZ_USERNAME") if u.id == ADMIN_ID and os.environ.get("LISTENBRAINZ_TOKEN") else None),
    }


def _issue_token(session: Session, user_id: str, label: str | None, request: Request | None = None) -> str:
    token = new_secret()
    session.add(AuthToken(token_hash=hash_secret(token), user_id=user_id, label=label))
    session.commit()
    user = session.get(AppUser, user_id)
    where = "z internetu" if request is not None and is_public(request) else "přes Tailscale"
    ip = client_ip(request) if request is not None else "?"
    notify(
        f"🔑 Nové zařízení: {user.name if user else user_id}",
        f"Přihlášení {where} · {ip}\n{(label or '')[:80]}",
        tags=["key"],
    )
    return token


@auth_router.get("/me")
def me(request: Request, response: Response):
    """Kdo jsem. V přechodném otevřeném režimu si zařízení bez klíče klíč
    admina vezme samo (nic se nezadává)."""
    user, acting = resolve_user(request)
    if user is None:
        return {"user": None, "acting": None, "mode": auth_mode(), "deviceCode": pair_code_required()}
    issued = None
    # Bez Tailscale účtu (ten zařízení pozná sám) a bez klíče: admin si ho
    # v otevřeném režimu vezme potichu.
    tailscale = bool(request.headers.get("tailscale-user-login"))
    if token_from_request(request) is None and not tailscale and auth_mode() == "open" and user.id == ADMIN_ID:
        with Session(engine) as session:
            issued = _issue_token(session, ADMIN_ID, request.headers.get("user-agent", "")[:120], request)
        # Web: cookie; nativní appka si klíč vezme z těla a posílá ho jako Bearer.
        _set_cookie(response, TOKEN_COOKIE, issued)
    return {"user": _user_out(user), "acting": _user_out(acting), "mode": auth_mode(), "token": issued,
            "tailscaleLogin": request.headers.get("tailscale-user-login"), "deviceCode": pair_code_required()}


class JoinIn(BaseModel):
    code: str


# Společný registrační odkaz: pozvánka s tímhle `user_id` jde použít
# opakovaně a každý, kdo ji otevře, si založí vlastní profil.
SIGNUP = "*signup*"


@auth_router.post("/join")
def join(body: JoinIn, request: Request, response: Response):
    """Pozvánka -> klíč tohoto zařízení (jednou na zařízení)."""
    if auth_mode() == "login":
        # S přihlašováním jde pozvánka jen přes /claim (jméno + heslo).
        raise HTTPException(status_code=403, detail="Použij pozvánku v přihlášení.")
    with Session(engine) as session:
        invite = session.exec(select(InviteCode).where(InviteCode.code_hash == hash_secret(body.code.strip()))).first()
        if invite is not None and invite.user_id == SIGNUP:
            # Opakovaně použitelný, ale jen do vypršení (nový se dá kdykoli
            # vytvořit v Profilech) -- dřív platil navždy.
            if aware(invite.expires_at) < utcnow():
                raise HTTPException(status_code=400, detail="Odkaz pro nové profily vypršel. Požádej o nový.")
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
        token = _issue_token(session, invite.user_id, request.headers.get("user-agent", "")[:120], request)
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
    token = _issue_token(session, user.id, request.headers.get("user-agent", "")[:120], request)
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
        session.add(InviteCode(code_hash=hash_secret(code), user_id=SIGNUP, expires_at=utcnow() + timedelta(days=7)))
        session.commit()
    return {"invite": code}


def _new_invite(session: Session, user_id: str) -> str:
    code = secrets.token_urlsafe(9)
    session.add(InviteCode(code_hash=hash_secret(code), user_id=user_id, expires_at=utcnow() + timedelta(days=_INVITE_DAYS)))
    session.commit()
    return code


def device_label(label: str | None) -> str:
    """Čitelný název zařízení: appka ho posílá při přihlášení (`device`),
    u starších klíčů se odhadne z User-Agent."""
    text = (label or "").strip()
    if text.startswith("device:"):
        return text[7:] or "Zařízení"
    for needle, name in (("iPhone", "iPhone"), ("iPad", "iPad"), ("Android", "Android"),
                         ("Windows", "Windows"), ("Macintosh", "Mac"), ("Linux", "Linux")):
        if needle in text:
            return f"{name} – prohlížeč" if "Mozilla" in text else f"{name} – appka"
    if "Dart/" in text or "opentify_client" in text:
        return "Appka"
    return "Zařízení"


@auth_router.get("/users")
def users(_admin=Depends(require_admin)):
    with Session(engine) as session:
        ensure_admin(session)
        rows = session.exec(select(AppUser).order_by(AppUser.created_at)).all()
        items = []
        for u in rows:
            tokens = session.exec(
                select(AuthToken).where(AuthToken.user_id == u.id).order_by(AuthToken.created_at.desc())  # type: ignore[union-attr]
            ).all()
            items.append({
                **_user_out(u),
                "devices": len(tokens),
                "deviceList": [
                    {
                        "id": t.id,
                        "label": device_label(t.label),
                        "lastUsedAt": (aware(t.last_used_at) or aware(t.created_at)).isoformat(),
                    }
                    for t in tokens
                ],
            })
        return {"items": items}


class NewUserIn(BaseModel):
    name: str
    username: str | None = None


def _clean_username(value: str | None) -> str | None:
    value = (value or "").strip()
    if not value:
        return None
    if len(value) < 3 or len(value) > 32 or any(ch.isspace() for ch in value):
        raise HTTPException(status_code=400, detail="Přihlašovací jméno: 3–32 znaků, bez mezer.")
    return value


def _username_taken(session: Session, username: str, except_id: str | None = None) -> bool:
    rows = session.exec(select(AppUser).where(AppUser.username.is_not(None))).all()  # type: ignore[union-attr]
    return any(u.username.lower() == username.lower() and u.id != except_id for u in rows)


@auth_router.post("/users")
def create_user(body: NewUserIn, _admin=Depends(require_admin)):
    name = body.name.strip()
    if not name:
        raise HTTPException(status_code=400, detail="Profil potřebuje jméno.")
    # Přihlašovací jméno si člověk vybere sám z pozvánky (`/auth/claim`).
    username = _clean_username(body.username)
    with Session(engine) as session:
        if username and _username_taken(session, username):
            raise HTTPException(status_code=409, detail="Tohle přihlašovací jméno už někdo má.")
        user = AppUser(name=name, role="user", username=username)
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


@auth_router.delete("/users/{user_id}")
def delete_user(user_id: str, _admin=Depends(require_admin)):
    """Smazat profil se všemi jeho daty (viz app/library/delete_profile.py)."""
    from app.library.delete_profile import delete_profile

    try:
        counts = delete_profile(user_id)
    except ValueError as e:
        raise HTTPException(status_code=400, detail=str(e)) from e
    except LookupError as e:
        raise HTTPException(status_code=404, detail=str(e)) from e
    return {"userId": user_id, "deleted": counts}


@auth_router.delete("/devices/{device_id}")
def revoke_device(device_id: str, request: Request, _admin=Depends(require_admin)):
    """Odhlásit jedno zařízení (ztracený telefon). Tohle zařízení ne --
    na to je Odhlásit se."""
    token = token_from_request(request)
    with Session(engine) as session:
        row = session.get(AuthToken, device_id)
        if row is None:
            raise HTTPException(status_code=404, detail="Zařízení už odhlášené.")
        if token and row.token_hash == hash_secret(token):
            raise HTTPException(status_code=400, detail="Tohle zařízení odhlas přes Odhlásit se.")
        session.delete(row)
        session.commit()
    return {"id": device_id, "revoked": True}


class ActAsIn(BaseModel):
    user_id: str | None = None


@auth_router.post("/act-as")
def act_as(body: ActAsIn, response: Response, _admin=Depends(require_admin)):
    """Admin: přepnout se na jiný profil (null = zpět na sebe)."""
    if body.user_id and body.user_id != ADMIN_ID:
        with Session(engine) as session:
            if session.get(AppUser, body.user_id) is None:
                raise HTTPException(status_code=404, detail="Profil neexistuje.")
    # Profil se určuje jen hlavičkou X-Act-As (appka); stará cookie pryč.
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
    # Z mobilu se token kopíruje i s mezerami/zalomením -- pryč (token je hex).
    token = "".join(body.token.split())
    if not token.isascii():
        raise HTTPException(status_code=400, detail="Tohle nevypadá jako token -- zkopíruj jen „User token“.")
    try:
        async with httpx.AsyncClient(timeout=40) as client:
            r = await client.get(f"{LB_API}/1/validate-token", headers={"Authorization": f"Token {token}"})
        data = r.json() if r.status_code == 200 else {}
    except (httpx.HTTPError, ValueError) as exc:
        logging.getLogger(__name__).warning("ListenBrainz validate-token selhal: %s: %s", type(exc).__name__, exc)
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


class LastfmFinishIn(BaseModel):
    token: str


@auth_router.post("/me/lastfm/start")
async def lastfm_start(request: Request):
    """Připojení vlastního Last.fm účtu profilu: vrátí odkaz na last.fm, kde
    ho uživatel schválí; pak `/me/lastfm/finish` s tokenem."""
    from app.catalog.lastfm import LastfmError
    from app.lastfm_scrobble import start_connect

    _user, acting = resolve_user(request)
    if acting is None:
        raise HTTPException(status_code=401, detail="Nepřihlášené zařízení.")
    try:
        return await start_connect()
    except LastfmError as exc:
        raise HTTPException(status_code=502, detail=str(exc)) from exc


@auth_router.post("/me/lastfm/finish")
async def lastfm_finish(body: LastfmFinishIn, request: Request):
    from app.catalog.lastfm import LastfmError
    from app.lastfm_scrobble import finish_connect

    _user, acting = resolve_user(request)
    if acting is None:
        raise HTTPException(status_code=401, detail="Nepřihlášené zařízení.")
    try:
        name = await finish_connect(acting.id, body.token.strip())
    except LastfmError as exc:
        raise HTTPException(status_code=400, detail=f"Last.fm: {exc}") from exc
    return {"lastfmUser": name}


@auth_router.delete("/me/lastfm")
async def lastfm_disconnect(request: Request):
    from app.lastfm_scrobble import disconnect

    _user, acting = resolve_user(request)
    if acting is None:
        raise HTTPException(status_code=401, detail="Nepřihlášené zařízení.")
    disconnect(acting.id)
    return {"lastfmUser": None}


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


_APPEARANCE_KEYS = {
    "appearance.glass_frost", "appearance.glass_tint", "appearance.glass_darkness",
    "appearance.glass_colorfulness", "appearance.glass_tint_main", "appearance.glass_accent_tint",
    "appearance.glass_tone", "appearance.glass_buttons", "appearance.glass_grain",
    "appearance.liquid_glass_test", "appearance.glass_off", "appearance.no_grain", "appearance.theme_mode",
}


class AppearanceIn(BaseModel):
    values: dict[str, bool | float | int | str]


@auth_router.get("/me/appearance")
def get_appearance(current: tuple[str, str] = Depends(get_current_user)):
    """Vzhled profilu uložený na serveru (prázdné = zařízení ho ještě neposlalo)."""
    with Session(engine) as session:
        user = session.get(AppUser, current[0])
        return {"values": (user.appearance if user else None) or {}}


@auth_router.put("/me/appearance")
def put_appearance(body: AppearanceIn, current: tuple[str, str] = Depends(get_current_user)):
    values = {k: v for k, v in body.values.items() if k in _APPEARANCE_KEYS}
    with Session(engine) as session:
        user = session.get(AppUser, current[0])
        if user is None:
            raise HTTPException(status_code=404, detail="Profil neexistuje.")
        user.appearance = {**(user.appearance or {}), **values}
        session.add(user)
        session.commit()
        return {"values": user.appearance}


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


class LoginIn(BaseModel):
    username: str
    password: str = ""
    # Název zařízení pro přehled admina ("iPhone – appka"...).
    device: str | None = None
    # První přihlášení / po vynulování: nové heslo (klient ho chce 2×).
    new_password: str | None = None
    # Kód zařízení (viz `pair_code_required`).
    code: str | None = None


_MIN_PASSWORD = 6
_LOGIN_FAILS = (8, 30)  # neúspěšných pokusů na jméno / na adresu ...
# (adresa je sdílená, když proxy nepošle X-Forwarded-For -- proto volněji)
_LOGIN_WINDOW = 15 * 60  # ... za 15 minut, pak stop do konce okna


def _client_ip(request: Request) -> str:
    # Poslední hodnotu přidává náš proxy (tailscale serve / nginx); první
    # může poslat klient sám.
    forwarded = [p.strip() for p in request.headers.get("x-forwarded-for", "").split(",") if p.strip()]
    return forwarded[-1] if forwarded else (request.client.host if request.client else "?")


def _fail_keys(request: Request, username: str) -> list[str]:
    return [f"login-fail:user:{username.lower()}", f"login-fail:ip:{_client_ip(request)}"]


async def _login_throttle(request: Request, username: str) -> None:
    """Pokus se započítá HNED (atomický INCR) a teprve pak se porovná s
    limitem -- souběžné pokusy tak limit neobejdou. Úspěšné přihlášení
    čítač jména vynuluje (`_login_ok`)."""
    try:
        r = get_redis()
        counts = []
        for k in _fail_keys(request, username):
            n = await r.incr(k)
            if n == 1:
                await r.expire(k, _LOGIN_WINDOW)
            counts.append(n)
    except Exception:  # noqa: BLE001 -- bez Redisu jen pomalé odmítnutí níž
        logging.getLogger(__name__).warning("login: Redis nedostupný, limit pokusů neplatí")
        return
    if any(c > limit for c, limit in zip(counts, _LOGIN_FAILS)):
        notify(
            "🔒 Někdo hádá heslo",
            f"Přihlašování zablokované na čtvrt hodiny · jméno {username[:40]} · {client_ip(request)}",
            tags=["lock"], priority=4, key=f"login:{username.lower()}", every_s=900,
        )
        raise HTTPException(status_code=429, detail="Moc pokusů. Zkus to za čtvrt hodiny.")


async def _login_ok(request: Request, username: str) -> None:
    try:
        await get_redis().delete(f"login-fail:user:{username.lower()}")
    except Exception:  # noqa: BLE001
        pass


# Stejná doba ověření pro neexistující jméno (jinak čas prozradí, jestli existuje).
_DUMMY_HASH: str | None = None


def _check_password(password: str, password_hash: str | None) -> bool:
    global _DUMMY_HASH
    if password_hash is None:
        if _DUMMY_HASH is None:
            _DUMMY_HASH = hash_password("opentify-dummy")
        verify_password(password, _DUMMY_HASH)
        return False
    return verify_password(password, password_hash)


@auth_router.post("/login")
async def login(body: LoginIn, request: Request, response: Response):
    """Jméno + heslo -> klíč zařízení (appka si ho pamatuje, web v cookie).
    Profil bez hesla se tu přihlásit nedá -- heslo si nastaví jen přes
    pozvánku (`/claim`), jinak by si ho mohl zvolit kdokoli, kdo zná jméno."""
    username = body.username.strip()
    await _login_throttle(request, username)
    need_code = pair_code_required()
    # Chybějící kód se hlásí PŘED ověřením hesla -- odpověď tak neprozradí,
    # jestli heslo sedělo.
    if need_code and len(_norm_pair(body.code)) != 8:
        raise HTTPException(
            status_code=401,
            detail="Zadej kód zařízení – vytvoří ho správce, nebo ty v Profilu na zařízení, kde už jsi přihlášený.",
        )
    with Session(engine) as session:
        rows = session.exec(select(AppUser).where(AppUser.username.is_not(None))).all()  # type: ignore[union-attr]
        user = next((u for u in rows if u.username.lower() == username.lower()), None)
        # scrypt mimo event loop -- jinak by každý pokus zastavil celé API.
        ok = await asyncio.to_thread(_check_password, body.password, user.password_hash if user else None)
        if ok and need_code:
            ok = _take_pair_code(session, user.id, body.code)
        if ok:
            await _login_ok(request, username)
        if not ok:
            session.rollback()
            await asyncio.sleep(1.0)  # zpomalit hádání
            raise HTTPException(
                status_code=401,
                detail="Špatné jméno, heslo nebo kód zařízení." if need_code else "Špatné jméno nebo heslo.",
            )
        token = _issue_token(session, user.id, _token_label(request, body.device), request)
        out = _user_out(user)
    _set_cookie(response, TOKEN_COOKIE, token)
    response.delete_cookie(ACT_AS_COOKIE, path="/")
    return {"user": out, "acting": out, "token": token}


def _token_label(request: Request, device: str | None) -> str:
    device = (device or "").strip()[:60]
    return f"device:{device}" if device else request.headers.get("user-agent", "")[:120]


class ClaimIn(BaseModel):
    code: str
    username: str | None = None
    password: str | None = None
    device: str | None = None


@auth_router.post("/claim")
async def claim(body: ClaimIn, request: Request, response: Response):
    """Pozvánka od admina -> člověk si sám vybere přihlašovací jméno a heslo.
    Bez jména/hesla jen ověří pozvánku (`needsAccount` + jméno profilu)."""
    with Session(engine) as session:
        invite = session.exec(select(InviteCode).where(InviteCode.code_hash == hash_secret(body.code.strip()))).first()
        if invite is None or invite.user_id == SIGNUP or invite.used_at is not None or aware(invite.expires_at) < utcnow():
            raise HTTPException(status_code=400, detail="Pozvánka neplatí (už použitá nebo prošlá). Požádej o novou.")
        user = session.get(AppUser, invite.user_id)
        if user is None:
            raise HTTPException(status_code=400, detail="Profil k pozvánce už neexistuje.")
        if body.username is None or body.password is None:
            return {"needsAccount": True, "name": user.name, "username": user.username}
        username = _clean_username(body.username)
        if not username:
            raise HTTPException(status_code=400, detail="Vyber si přihlašovací jméno.")
        if _username_taken(session, username, except_id=user.id):
            raise HTTPException(status_code=409, detail="Tohle jméno už někdo má, zkus jiné.")
        if len(body.password) < _MIN_PASSWORD:
            raise HTTPException(status_code=400, detail=f"Heslo aspoň {_MIN_PASSWORD} znaků.")
        user.username = username
        user.password_hash = hash_password(body.password)
        invite.used_at = utcnow()
        session.add(user)
        session.add(invite)
        session.commit()
        session.refresh(user)
        token = _issue_token(session, user.id, _token_label(request, body.device), request)
        out = _user_out(user)
    _set_cookie(response, TOKEN_COOKIE, token)
    response.delete_cookie(ACT_AS_COOKIE, path="/")
    return {"user": out, "acting": out, "token": token}


@auth_router.post("/logout")
def logout(request: Request, response: Response):
    """Odhlásit TOHLE zařízení (smaže jeho klíč)."""
    token = token_from_request(request)
    if token:
        with Session(engine) as session:
            for row in session.exec(select(AuthToken).where(AuthToken.token_hash == hash_secret(token))).all():
                session.delete(row)
            session.commit()
    response.delete_cookie(TOKEN_COOKIE, path="/")
    response.delete_cookie(ACT_AS_COOKIE, path="/")
    return {"loggedOut": True}


class UserPatchIn(BaseModel):
    name: str | None = None
    username: str | None = None


@auth_router.patch("/users/{user_id}")
def update_user(user_id: str, body: UserPatchIn, _admin=Depends(require_admin)):
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        if user is None:
            raise HTTPException(status_code=404, detail="Profil neexistuje.")
        if body.name is not None and body.name.strip():
            user.name = body.name.strip()
        if body.username is not None:
            username = _clean_username(body.username)
            if username and _username_taken(session, username, except_id=user.id):
                raise HTTPException(status_code=409, detail="Tohle přihlašovací jméno už někdo má.")
            user.username = username
        session.add(user)
        session.commit()
        session.refresh(user)
        return _user_out(user)


@auth_router.post("/pair-code")
def my_pair_code(current: tuple[str, str] = Depends(require_admin)):
    """"Přidat zařízení": kód pro další vlastní zařízení -- JEN admin.
    Kódy pro nová zařízení vydává výhradně admin (pravidlo majitele);
    ostatní profily si kód samy vytvořit nesmí."""
    user_id, _device = current
    with Session(engine) as session:
        code, expires = new_pair_code(session, user_id, user_id)
    return {"code": code, "expiresAt": expires, "hours": _PAIR_HOURS}


@auth_router.post("/users/{user_id}/pair-code")
def user_pair_code(user_id: str, admin=Depends(require_admin)):
    """Admin: kód pro nové zařízení profilu (táta, kamarád)."""
    with Session(engine) as session:
        if session.get(AppUser, user_id) is None:
            raise HTTPException(status_code=404, detail="Profil neexistuje.")
        code, expires = new_pair_code(session, user_id, ADMIN_ID)
    return {"code": code, "expiresAt": expires, "hours": _PAIR_HOURS}


@auth_router.post("/users/{user_id}/reset-password")
def reset_password(user_id: str, _admin=Depends(require_admin)):
    """Zapomenuté heslo: zrušit ho, odhlásit všechna zařízení a vydat novou
    pozvánku -- přes ni si člověk nastaví nové heslo (jméno mu zůstane)."""
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        if user is None:
            raise HTTPException(status_code=404, detail="Profil neexistuje.")
        user.password_hash = None
        session.add(user)
        for row in session.exec(select(AuthToken).where(AuthToken.user_id == user_id)).all():
            session.delete(row)
        session.commit()
        code = _new_invite(session, user_id)
    return {"userId": user_id, "reset": True, "invite": code}
