"""Hlídání přihlášení slskd do Soulseeku a dotaz bez zdvojených slov (13. 10.)."""
import asyncio

from app import slskd_watch
from app.providers import _soulseek_words


def test_dotaz_bez_zdvojeneho_jmena():
    assert _soulseek_words("Denison Witmer", "Denison Witmer Live at Schubas") == "Denison Witmer Live at Schubas"


class _Redis:
    def __init__(self):
        self.data = {}

    async def get(self, k):
        return self.data.get(k)

    async def set(self, k, v):
        self.data[k] = v

    async def delete(self, k):
        return 1 if self.data.pop(k, None) is not None else 0


class _Resp:
    def __init__(self, body):
        self.body = body

    def json(self):
        return self.body


def _client(state, calls):
    class Client:
        def __init__(self, **_kw):
            pass

        async def __aenter__(self):
            return self

        async def __aexit__(self, *_a):
            return False

        async def get(self, path):
            return _Resp({"state": state["now"], "isLoggedIn": "LoggedIn" in state["now"]})

        async def delete(self, path):
            calls.append("delete")

        async def put(self, path):
            calls.append("put")

    return Client


def test_odpojeny_po_lhute_pripoji_znovu(monkeypatch):
    state, calls, sent = {"now": "Disconnecting"}, [], []
    monkeypatch.setattr(slskd_watch.httpx, "AsyncClient", _client(state, calls))
    monkeypatch.setattr("app.notify.notify", lambda *a, **k: sent.append(a[0]) or True)
    r = _Redis()
    clock = [1000.0]
    monkeypatch.setattr(slskd_watch.time, "time", lambda: clock[0])

    assert asyncio.run(slskd_watch.check(r)) == "Disconnecting"
    assert calls == []  # první pozorování, čeká se
    clock[0] += 60
    asyncio.run(slskd_watch.check(r))
    assert calls == []  # ještě ve lhůtě
    clock[0] += 90
    asyncio.run(slskd_watch.check(r))
    assert calls == ["delete", "put"] and sent == ["Soulseek odpojený"]
    state["now"] = "Connected, LoggedIn"
    assert asyncio.run(slskd_watch.check(r)) is None
    assert sent[-1] == "Soulseek zase běží" and not r.data
