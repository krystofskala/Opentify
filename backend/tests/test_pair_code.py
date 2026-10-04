"""Kód zařízení k jménu a heslu: bez platného kódu TOHOTO profilu se nové
zařízení nepřihlásí; kód platí jen jednou a jen poslední vytvořený."""
from __future__ import annotations

import pytest
from fastapi.testclient import TestClient
from sqlmodel import Session

from app.auth import hash_password
from app.db import engine
from app.main import app
from app.models import AppUser
from app.routes.auth import new_pair_code


@pytest.fixture(autouse=True)
def no_redis(monkeypatch):
    """Omezení pokusů nesmí sahat na živý Redis (testy by si ho zablokovaly)."""
    import app.routes.auth as auth_routes

    def boom():
        raise RuntimeError("bez Redisu v testech")

    monkeypatch.setattr(auth_routes, "get_redis", boom)


@pytest.fixture
def users():
    with Session(engine) as s:
        a = AppUser(name="A", username="pair-a", password_hash=hash_password("heslo123"))
        b = AppUser(name="B", username="pair-b", password_hash=hash_password("heslo456"))
        s.add_all([a, b])
        s.commit()
        s.refresh(a)
        s.refresh(b)
        yield a, b
        s.delete(a)
        s.delete(b)
        s.commit()


def _login(client: TestClient, username: str, password: str, code: str | None):
    body = {"username": username, "password": password}
    if code is not None:
        body["code"] = code
    return client.post("/api/v1/auth/login", json=body)


def _code(user_id: str) -> str:
    with Session(engine) as s:
        return new_pair_code(s, user_id, "test")[0]


def test_login_needs_device_code(users, monkeypatch):
    monkeypatch.setenv("LOGIN_DEVICE_CODE", "1")
    a, b = users
    client = TestClient(app)
    # Bez kódu: odmítnuto ještě před heslem (správné heslo nic neprozradí).
    r = _login(client, "pair-a", "heslo123", None)
    assert r.status_code == 401 and "kód zařízení" in r.json()["detail"]
    # Kód jiného profilu nepomůže.
    assert _login(client, "pair-a", "heslo123", _code(b.id)).status_code == 401
    code = _code(a.id)
    # Správný kód, špatné heslo -> nic (a kód se nespotřebuje).
    assert _login(client, "pair-a", "spatne", code).status_code == 401
    r = _login(client, "pair-a", "heslo123", code.lower().replace("-", " "))
    assert r.status_code == 200 and r.json()["token"]
    # Jednorázový.
    assert _login(client, "pair-a", "heslo123", code).status_code == 401


def test_only_latest_code_counts(users, monkeypatch):
    monkeypatch.setenv("LOGIN_DEVICE_CODE", "1")
    a, _b = users
    client = TestClient(app)
    old = _code(a.id)
    new = _code(a.id)
    assert _login(client, "pair-a", "heslo123", old).status_code == 401
    assert _login(client, "pair-a", "heslo123", new).status_code == 200


def test_code_can_be_disabled(users, monkeypatch):
    monkeypatch.setenv("LOGIN_DEVICE_CODE", "0")
    client = TestClient(app)
    assert _login(client, "pair-a", "heslo123", None).status_code == 200
