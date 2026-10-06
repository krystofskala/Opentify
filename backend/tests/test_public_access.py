"""Veřejný internet (Funnel): žádná správa, jen s přihlášením, omezení IP."""
import pytest
from fastapi import HTTPException
from fastapi.testclient import TestClient
from starlette.requests import Request

import app.public_access as pa
from app.auth import require_admin
from app.main import app

FUNNEL = {"Tailscale-Funnel-Request": "?1"}


def _request(headers: dict[str, str]) -> Request:
    raw = [(k.lower().encode(), v.encode()) for k, v in headers.items()]
    return Request({"type": "http", "method": "GET", "path": "/", "headers": raw, "query_string": b"", "client": ("1.2.3.4", 1)})


def test_admin_never_from_public_internet():
    with pytest.raises(HTTPException) as e:
        require_admin(_request({**FUNNEL, "Authorization": "Bearer cokoli"}))
    assert e.value.status_code == 403


def test_public_requests_need_login_mode(monkeypatch):
    client = TestClient(app)
    monkeypatch.setenv("AUTH_MODE", "open")
    assert client.get("/health", headers=FUNNEL).status_code == 403
    assert client.get("/health").status_code == 200  # tailnet beze změny
    monkeypatch.setenv("AUTH_MODE", "login")
    assert client.get("/health", headers=FUNNEL).status_code == 200


def test_public_rate_limit_per_ip(monkeypatch):
    monkeypatch.setattr(pa, "PUBLIC_RATE_PER_MIN", 3)
    monkeypatch.setattr(pa, "_hits", {})
    monkeypatch.setenv("AUTH_MODE", "login")
    client = TestClient(app)
    h = {**FUNNEL, "X-Forwarded-For": "203.0.113.7"}
    codes = [client.get("/health", headers=h).status_code for _ in range(4)]
    assert codes == [200, 200, 200, 429]
    # jiná IP má vlastní limit, tailnet žádný
    assert client.get("/health", headers={**FUNNEL, "X-Forwarded-For": "203.0.113.8"}).status_code == 200
    assert client.get("/health").status_code == 200


def test_sliding_window_forgets_old_hits():
    pa._hits.clear()
    assert not any(pa.over_limit("x", now=t, limit=2) for t in (0, 1))
    assert pa.over_limit("x", now=2, limit=2)
    assert not pa.over_limit("x", now=62, limit=2)
