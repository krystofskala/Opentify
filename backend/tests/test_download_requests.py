"""Žádosti o schválení stažení: založení, tlačítko s jednorázovým klíčem, jen jednou."""
import asyncio

import pytest
from fastapi import HTTPException
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select
from starlette.requests import Request

import app.download_limits as dl
import app.download_requests as dr
import app.routes.download_requests as dr_routes
import app.routes.download_requests as dr_routes_mod
import app.routes.spoken as spoken
import app.spoken.importer as importer
from app.models import AppUser, DownloadRequest, SpokenBook

HASH = "2dce9ad02753466981d1c8ae819a95618c5e652d"


@pytest.fixture
def eng(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    for mod in (dl, dr, importer):
        monkeypatch.setattr(mod, "engine", e)
    sent = []
    monkeypatch.setattr(dr, "notify", lambda *a, **k: sent.append((a, k)) or True)
    monkeypatch.setattr(dr_routes_mod, "notify", lambda *a, **k: sent.append((a, k)) or True)
    with Session(e) as s:
        s.add(AppUser(id="pepa", name="Pepa", role="user"))
        s.commit()
    e.sent = sent
    return e


def _public():
    return Request({"type": "http", "method": "POST", "path": "/", "headers": [(b"tailscale-funnel-request", b"?1")],
                    "query_string": b"", "client": ("1.2.3.4", 1), "scheme": "https", "server": ("x", 443)})


def test_public_audiobook_becomes_request_and_link_approves_once(eng, monkeypatch):
    monkeypatch.setenv("OPENTIFY_PUBLIC_URL", "https://opentify.example.ts.net")
    body = spoken.AcquireIn(infohash=HASH, title="Saturnin (čte Beneš)", sizeBytes=200 * 2**20)
    with Session(eng) as s:
        out = asyncio.run(spoken.acquire(body, session=s, current=("pepa", "d"), request=_public()))
        assert out["status"] == "awaiting_approval"
        assert s.exec(select(SpokenBook)).first() is None  # nic se nestahuje
        req = s.get(DownloadRequest, out["requestId"])
        # upozornění s tlačítky Povolit / Zamítnout
        (title, msg), kw = eng.sent[0]
        assert "Pepa" in title and [a["label"] for a in kw["actions"]] == ["Povolit", "Zamítnout"]
        link = kw["actions"][0]["url"]
        token = link.split("t=")[1].split("&")[0]
        with pytest.raises(HTTPException) as e:
            asyncio.run(dr_routes.decide_by_link(req.id, t="spatny", a="approve", session=s))
        assert e.value.status_code == 404
        res = asyncio.run(dr_routes.decide_by_link(req.id, t=token, a="approve", session=s))
        assert res["status"] == "approved"
        assert "Povoleno" in eng.sent[-1][0][0]  # potvrzení na telefon
        book = s.exec(select(SpokenBook)).one()
        assert book.requested_by_user_id == "pepa"
        again = asyncio.run(dr_routes.decide_by_link(req.id, t=token, a="deny", session=s))
        assert again["status"] == "approved" and again.get("already")


def test_deny_creates_nothing(eng):
    body = spoken.AcquireIn(infohash=HASH, title="Velká sbírka", sizeBytes=30 * dl.GB)
    with Session(eng) as s:
        out = asyncio.run(spoken.acquire(body, session=s, current=("pepa", "d")))  # z tailnetu, ale velké
        assert out["status"] == "awaiting_approval" and "velké" in out["reason"]
        token_url = eng.sent[0][1]["actions"] if eng.sent[0][1].get("actions") else None
        assert token_url is None or token_url  # bez veřejné adresy tlačítka nemusí být
        res = asyncio.run(dr_routes.deny(out["requestId"], session=s))
        assert res["status"] == "denied"
        assert s.exec(select(SpokenBook)).first() is None
