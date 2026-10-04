"""Záložní poslechy ze stavu Connect: zapíše se, co opravdu hrálo, přetočení
se nepočítá, a poslech nahlášený appkou se nezdvojí."""
from datetime import datetime, timezone

from sqlmodel import Session, select

import app.connect_listens as cl
from app.db import engine
from app.listens import record_listen
from app.models import Listen, Recording


def _rec(title, ms):
    with Session(engine) as s:
        r = Recording(title=title, duration_ms=ms)
        s.add(r)
        s.commit()
        return r.id


def _state(rid, pos, playing=True, dur=200_000):
    return {"nowPlaying": {"recordingId": rid}, "isPlaying": playing, "positionMs": pos, "durationMs": dur}


def _count(user):
    with Session(engine) as s:
        return len(s.exec(select(Listen).where(Listen.user_id == user)).all())


def test_records_played_track_and_skips_seek(monkeypatch):
    t = [1_000_000.0]
    monkeypatch.setattr(cl.time, "time", lambda: t[0])
    tr = cl.ConnectListens()
    a, b, c = _rec("A", 200_000), _rec("B", 200_000), _rec("C", 200_000)
    # A hraje 120 s (stavy po 15 s) -> poslech.
    for i in range(9):
        tr.update("cl-user", "dev", _state(a, i * 15_000))
        t[0] += 15
    # B: přetočeno skoro na konec za 5 s -> nic.
    tr.update("cl-user", "dev", _state(b, 0))
    t[0] += 5
    tr.update("cl-user", "dev", _state(b, 190_000))
    t[0] += 5
    tr.update("cl-user", "dev", _state(c, 0))
    assert _count("cl-user") == 1


def test_no_duplicate_when_app_reported(monkeypatch):
    t = [2_000_000.0]
    monkeypatch.setattr(cl.time, "time", lambda: t[0])
    tr = cl.ConnectListens()
    a, b = _rec("D", 200_000), _rec("E", 200_000)
    tr.update("cl-user2", "dev", _state(a, 0))
    # Appka sama nahlásí (začátek o pár sekund jinak).
    record_listen("cl-user2", a, played_at=datetime.fromtimestamp(t[0] + 3, tz=timezone.utc), duration_played_ms=100_000)
    for _ in range(9):
        t[0] += 15
        tr.update("cl-user2", "dev", _state(a, int((t[0] - 2_000_000.0) * 1000)))
    tr.update("cl-user2", "dev", _state(b, 0))
    assert _count("cl-user2") == 1
