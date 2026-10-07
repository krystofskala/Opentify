"""Port z ProtonVPN do slskd: nastaví se jen, když se liší (app/vpn_ports.py)."""
import asyncio
import json

import httpx

from app import vpn_ports


def run(monkeypatch, gluetun_port, slskd_port):
    calls = []

    def handler(request: httpx.Request) -> httpx.Response:
        calls.append((request.method, request.url.path, request.content.decode() or None))
        if request.url.path == "/v1/portforward":
            return httpx.Response(200, json={"port": gluetun_port})
        if request.url.path == "/api/v0/options" and request.method == "GET":
            return httpx.Response(200, json={"soulseek": {"listenPort": slskd_port}})
        return httpx.Response(200, json={})

    real = httpx.AsyncClient

    class _Client(real):  # type: ignore[misc, valid-type]
        def __init__(self, *a, **k):
            k["transport"] = httpx.MockTransport(handler)
            super().__init__(*a, **k)

    monkeypatch.setattr(vpn_ports.httpx, "AsyncClient", _Client)
    monkeypatch.setenv("SLSK_GLUETUN_CONTROL_URL", "http://gluetun-slsk:8000")
    monkeypatch.setenv("SLSK_GLUETUN_CONTROL_API_KEY", "k")
    monkeypatch.setenv("SLSKD_URL", "http://gluetun-slsk:5030")
    return asyncio.run(vpn_ports.sync_slskd_port()), calls


def test_sets_port_when_different(monkeypatch):
    port, calls = run(monkeypatch, 62301, 50300)
    assert port == 62301
    assert ("PATCH", "/api/v0/options", json.dumps({"soulseek": {"listenPort": 62301}})) in [
        (m, p, json.dumps(json.loads(b)) if b else b) for m, p, b in calls
    ]


def test_nothing_when_same_or_disabled(monkeypatch):
    port, calls = run(monkeypatch, 62301, 62301)
    assert port is None and not any(m == "PATCH" for m, _, _ in calls)
    monkeypatch.delenv("SLSK_GLUETUN_CONTROL_URL")
    assert asyncio.run(vpn_ports.sync_slskd_port()) is None
