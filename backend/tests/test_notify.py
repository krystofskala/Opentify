"""Upozornění správci: jen s NTFY_URL, nikdy neshodí požadavek, potlačení opakování."""
import app.notify as n


def test_off_without_url(monkeypatch):
    monkeypatch.delenv("NTFY_URL", raising=False)
    assert n.notify("x", "y") is False


def test_throttled_by_key(monkeypatch):
    sent = []
    monkeypatch.setenv("NTFY_URL", "https://ntfy.example/tajny-kanal")
    monkeypatch.setattr(n.httpx, "post", lambda url, json, timeout: sent.append((url, json)) or type("R", (), {"raise_for_status": lambda self: None})())
    monkeypatch.setattr(n, "_last", {})
    assert n.notify("A", "b", key="k", every_s=600) is True
    assert n.notify("A", "b", key="k", every_s=600) is False
    import time; time.sleep(0.2)
    assert sent and sent[0][0] == "https://ntfy.example/" and sent[0][1]["topic"] == "tajny-kanal"


def test_send_error_is_swallowed(monkeypatch):
    monkeypatch.setenv("NTFY_URL", "https://ntfy.example/k")
    def boom(*a, **k):
        raise RuntimeError("síť nejde")
    monkeypatch.setattr(n.httpx, "post", boom)
    monkeypatch.setattr(n, "_last", {})
    assert n.notify("A", "b") is True  # odesláno na pozadí, chyba jen v logu


def test_failed_login_from_internet_notifies_once_per_ip(monkeypatch):
    from starlette.requests import Request

    import app.routes.auth as auth_routes

    calls = []
    monkeypatch.setattr(auth_routes, "notify", lambda *a, **k: calls.append((a, k)) or True)

    def req(headers):
        raw = [(k.lower().encode(), v.encode()) for k, v in headers.items()]
        return Request({"type": "http", "method": "POST", "path": "/", "headers": raw, "query_string": b"", "client": ("1.2.3.4", 1)})

    auth_routes._notify_failed_login(req({}), "admin", "x")  # z tailnetu nic
    assert calls == []
    auth_routes._notify_failed_login(req({"Tailscale-Funnel-Request": "?1", "X-Forwarded-For": "203.0.113.9"}), "admin", "x")
    assert len(calls) == 1 and "203.0.113.9" in calls[0][0][1] and calls[0][1]["key"] == "login-fail:203.0.113.9"
