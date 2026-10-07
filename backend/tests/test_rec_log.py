"""Měření doporučování: várka -> přehrání se k ní připojí -> přehled."""
from __future__ import annotations

import time
import uuid
from datetime import timedelta

from sqlmodel import Session, select

from app import connect_listens, rec_log
from app.db import engine
from app.models import AppUser, Artist, Listen, PlayEvent, Recording
from app.utils import utcnow

_RUN = uuid.uuid4().hex[:8]


def _setup():
    user = "rl-" + _RUN + "-" + uuid.uuid4().hex[:4]
    with Session(engine) as s:
        s.add(AppUser(id=user, name="Měření " + _RUN, role="user"))
        a = Artist(name="RL Artist " + _RUN)
        b = Artist(name="RL Other " + _RUN)
        s.add_all([a, b])
        s.flush()
        recs = [Recording(title=f"rl song {i}", artist_id=(a if i % 2 else b).id, duration_ms=200_000) for i in range(4)]
        s.add_all(recs)
        s.commit()
        return user, [r.id for r in recs]


def test_batch_play_is_matched_and_reported():
    user, ids = _setup()
    batch = rec_log.log_batch(user, ids, {ids[3]}, "endless")
    assert batch
    # Přehrání z "alba" (fronta nese jiný název) se přesto pozná jako z várky.
    started = time.time() - 200
    connect_listens._play_event(user, "dev", ids[0], started, 195.0, 200_000, "completed", "Nějaké album")
    connect_listens._play_event(user, "dev", ids[3], started, 5.0, 200_000, "skipped", "Nějaké album", True)
    with Session(engine) as s:
        rows = s.exec(select(PlayEvent).where(PlayEvent.user_id == user)).all()
        by = {r.recording_id: r for r in rows}
        assert by[ids[0]].rec_batch_id == batch and by[ids[0]].rec_slot == "familiar" and by[ids[0]].algorithmic
        assert by[ids[3]].rec_slot == "new"
        # Nová skladba poslechnutá znovu později = přijatá.
        s.add(Listen(user_id=user, recording_id=ids[3], played_at=(utcnow() + timedelta(hours=1)).replace(tzinfo=None),
                     duration_played_ms=200_000))
        s.commit()
    rep = {r["userId"]: r for r in rec_log.report(7)}[user]
    assert rep["batches"] == 1 and rep["offered"] == 4 and rep["played"] == 2
    assert rep["earlySkipPct"] == 50 and rep["completedPct"] == 50
    assert rep["newPlayed"] == 1 and rep["newAccepted"] == 1


def test_old_batches_do_not_match():
    user, ids = _setup()
    rec_log.log_batch(user, ids[:1], set(), "fresh")
    with Session(engine) as s:
        from app.models import RecBatchItem

        item = s.exec(select(RecBatchItem).where(RecBatchItem.user_id == user)).first()
        item.created_at = (utcnow() - timedelta(hours=rec_log.MATCH_HOURS + 1)).replace(tzinfo=None)
        s.add(item)
        s.commit()
        assert rec_log.match(s, user, ids[0]) is None
