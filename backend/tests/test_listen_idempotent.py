"""Opakované odeslání stejného poslechu (výpadek signálu) se nezdvojí."""
from datetime import datetime, timezone

from sqlmodel import Session, select

from app.db import engine
from app.listens import record_listen
from app.models import Listen, Recording


def test_same_listen_recorded_once():
    with Session(engine) as s:
        rec = Recording(title="Idem")
        s.add(rec)
        s.commit()
        rid = rec.id
    at = datetime(2026, 10, 4, 16, 30, 0, 123000, tzinfo=timezone.utc)
    a = record_listen("idem-user", rid, played_at=at, duration_played_ms=200000)
    b = record_listen("idem-user", rid, played_at=at, duration_played_ms=200000)
    c = record_listen("idem-user", rid, played_at=datetime(2026, 10, 4, 16, 40, tzinfo=timezone.utc), duration_played_ms=1)
    assert a == b and c != a
    with Session(engine) as s:
        assert len(s.exec(select(Listen).where(Listen.user_id == "idem-user")).all()) == 2
