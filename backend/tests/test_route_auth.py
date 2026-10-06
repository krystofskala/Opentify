"""Bezpečnostní pojistka: každá routa API vyžaduje přihlášení, admin akce
admina. Přidáváš veřejnou nebo admin routu? Uprav seznamy níž -- vědomě.

Routa je "chráněná", když má v závislostech `get_current_user` /
`require_admin` (i z routeru), nebo je v těle volá sama
(`get_current_user(request)` u endpointů s `Request`)."""
from __future__ import annotations

import inspect

from fastapi.routing import APIRoute

from app.auth import get_current_user, require_admin
from app.main import app

# Bez přihlášení schválně: přihlášení/pozvánky, obaly alb (<img> neposílá
# hlavičky, obsah není osobní), živý stream rádia (náhodné 128bit id relace).
PUBLIC = {
    ("GET", "/health"),
    ("GET", "/api/v1/auth/me"),
    ("POST", "/api/v1/auth/join"),
    ("POST", "/api/v1/auth/claim"),
    ("POST", "/api/v1/auth/login"),
    ("POST", "/api/v1/auth/logout"),
    ("GET", "/api/v1/artwork/releases/{release_id}"),
    ("GET", "/api/v1/radio/{session_id}/stream"),
    ("GET", "/api/v1/radio/{session_id}/index.m3u8"),
    ("GET", "/api/v1/radio/{session_id}/{name}"),
}

# Jen admin: správa profilů a zařízení, údržba knihovny a stahování.
ADMIN = {
    ("GET", "/api/v1/auth/users"),
    ("POST", "/api/v1/auth/users"),
    ("PATCH", "/api/v1/auth/users/{user_id}"),
    ("DELETE", "/api/v1/auth/users/{user_id}"),
    ("POST", "/api/v1/auth/users/{user_id}/invite"),
    ("DELETE", "/api/v1/auth/users/{user_id}/devices"),
    ("POST", "/api/v1/auth/users/{user_id}/reset-password"),
    ("DELETE", "/api/v1/auth/devices/{device_id}"),
    ("POST", "/api/v1/auth/act-as"),
    ("POST", "/api/v1/auth/signup-link"),
    ("POST", "/api/v1/auth/users/{user_id}/pair-code"),
    ("POST", "/api/v1/auth/pair-code"),
    ("POST", "/api/v1/library/scan"),
    ("GET", "/api/v1/library/verify-report"),
    ("POST", "/api/v1/library/verify/{recording_id}"),
    ("POST", "/api/v1/library/verify-report/{recording_id}/ok"),
    ("POST", "/api/v1/library/verify-report/{recording_id}/redownload"),
    ("POST", "/api/v1/library/verify-report/{recording_id}/relabel"),
    ("DELETE", "/api/v1/library/imported-releases/{release_id}"),
    ("GET", "/api/v1/library/soulseek"),
    ("POST", "/api/v1/catalog/artists/{artist_id}/releases/{release_id}/not-artist"),
}


def _calls(dependant) -> set:
    out = set()
    for dep in dependant.dependencies:
        out.add(dep.call)
        out |= _calls(dep)
    return out


def _flatten(routes, prefix: str = "", deps: tuple = ()):
    """FastAPI >= 0.14x drží `include_router` vnořeně (`_IncludedRouter`) --
    cesta = prefixy, závislosti = z include_router + z routy."""
    for route in routes:
        ctx = getattr(route, "include_context", None)
        if ctx is not None:
            inner = tuple(d.dependency for d in ctx.dependencies or [])
            yield from _flatten(route.original_router.routes, prefix + (ctx.prefix or ""), deps + inner)
        elif isinstance(route, APIRoute):
            yield prefix + route.path, route, deps


class _Route:
    def __init__(self, path: str, route: APIRoute, deps: tuple) -> None:
        self.path, self.route, self.deps = path, route, deps


def _routes():
    for path, route, deps in _flatten(app.routes):
        for method in route.methods - {"HEAD", "OPTIONS"}:
            yield method, _Route(path, route, deps)


def _protection(r: _Route) -> str | None:
    route = r.route
    calls = _calls(route.dependant) | set(r.deps)
    source = inspect.getsource(route.endpoint)
    if require_admin in calls or "require_admin(request" in source:
        return "admin"
    if get_current_user in calls or "get_current_user(request" in source or "resolve_user(request" in source:
        return "user"
    return None


def test_every_route_requires_login():
    unprotected = sorted(
        f"{m} {r.path}" for m, r in _routes() if (m, r.path) not in PUBLIC and _protection(r) is None
    )
    assert not unprotected, f"Routy bez přihlášení (přidej závislost, nebo vědomě do PUBLIC): {unprotected}"


def test_admin_routes_stay_admin():
    known = {(m, r.path): r for m, r in _routes()}
    missing = sorted(f"{m} {p}" for m, p in ADMIN if (m, p) not in known)
    assert not missing, f"ADMIN obsahuje routy, které už neexistují: {missing}"
    downgraded = sorted(f"{m} {p}" for (m, p) in ADMIN if _protection(known[(m, p)]) != "admin")
    assert not downgraded, f"Admin routy bez require_admin: {downgraded}"


def test_new_admin_routes_are_listed():
    unlisted = sorted(f"{m} {r.path}" for m, r in _routes() if _protection(r) == "admin" and (m, r.path) not in ADMIN)
    assert not unlisted, f"Nové admin routy -- doplň do ADMIN (ať se hlídají): {unlisted}"


def test_public_list_is_current():
    known = {(m, r.path) for m, r in _routes()}
    stale = sorted(f"{m} {p}" for m, p in PUBLIC if (m, p) not in known)
    assert not stale, f"PUBLIC obsahuje routy, které už neexistují: {stale}"
