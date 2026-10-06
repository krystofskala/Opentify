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
