"""Falešné údaje z .env: použití = poplach a odmítnutí, nic se neprozradí."""
from __future__ import annotations

from fastapi.testclient import TestClient

import hashlib

TOKEN = "otk_live_9f3c2a7d51e84b06"


def _sha(v: str) -> str:
    return hashlib.sha256(v.encode()).hexdigest()


def _client(monkeypatch, sent):
    import app.notify as notify_mod
    from app.main import app

    monkeypatch.setenv("REQUEST_DENY_SHA256", _sha(TOKEN))
    monkeypatch.setenv("LOGIN_DENY_SHA256", _sha("spravce-zaloha"))
    monkeypatch.setattr(notify_mod, "notify", lambda title, msg, **kw: sent.append((title, msg, kw)))
    return TestClient(app)


def test_token_in_header_or_query_alarms(monkeypatch):
    sent: list = []
    client = _client(monkeypatch, sent)
    assert client.get("/health", headers={"Authorization": f"Bearer {TOKEN}"}).status_code == 403
    assert client.get(f"/health?key={TOKEN}").status_code == 403
    assert client.get("/health", headers={"X-Api-Key": TOKEN + "x"}).status_code == 200  # jen celá hodnota
    assert client.get("/health").status_code == 200
    assert len(sent) == 2 and sent[0][2]["priority"] == 5
    assert all(TOKEN not in title + msg for title, msg, _ in sent)  # hodnota se nikam neposílá


def test_decoy_username_alarms(monkeypatch):
    sent: list = []
    client = _client(monkeypatch, sent)
    r = client.post("/api/v1/auth/login", json={"username": "Spravce-Zaloha", "password": "x", "code": ""})
    assert r.status_code == 401
    assert any("falešný účet" in msg for _t, msg, _k in sent)


def test_nothing_configured_nothing_happens(monkeypatch):
    from fastapi import Request

    from app import canary

    monkeypatch.delenv("REQUEST_DENY_SHA256", raising=False)
    req = Request({"type": "http", "method": "GET", "path": "/", "query_string": TOKEN.encode(), "headers": []})
    assert canary.check_request(req) is False
