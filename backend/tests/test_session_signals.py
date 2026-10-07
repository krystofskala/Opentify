"""Signály relace (audit 7. 10., mezera 3): proklikávání vlastního alba není
"nelíbí se" a přeskočená skladba není semínko nekonečného hraní."""

import uuid
from datetime import timedelta

from sqlmodel import Session

from app.db import engine
from app.home import play_now as pn
from app.models import Artist, PlayEvent, Recording
from app.utils import utcnow

_RUN = uuid.uuid4().hex[:8]


def _recs(n: int) -> list[str]:
    with Session(engine) as s:
        a = Artist(name="Session " + _RUN + uuid.uuid4().hex[:4])
        s.add(a)
        s.flush()
        recs = [Recording(title=f"t{i}", artist_id=a.id) for i in range(n)]
        s.add_all(recs)
        s.commit()
        return [r.id for r in recs]


def _play(user: str, rid: str, reason: str, algo: bool, minutes_ago: float) -> None:
    end = utcnow() - timedelta(minutes=minutes_ago)
    with Session(engine) as s:
        s.add(PlayEvent(user_id=user, recording_id=rid, started_at=end - timedelta(seconds=10), ended_at=end,
                        played_ms=10_000, end_reason=reason, algorithmic=algo))
        s.commit()


def test_browsing_own_album_does_not_turn_direction() -> None:
    user = "sess-own-" + _RUN
    r = _recs(3)
    for i, rid in enumerate(r):
        _play(user, rid, "skipped", False, 5 - i)  # proklikává si vlastní album
    with Session(engine) as s:
        skipped, _done, turn = pn._session_signals(s, user)
    assert not turn and not skipped


def test_two_algorithmic_skips_turn_direction() -> None:
    user = "sess-algo-" + _RUN
    r = _recs(3)
    _play(user, r[0], "completed", True, 6)
    _play(user, r[1], "skipped", True, 4)
    _play(user, r[2], "skipped", False, 3)  # vlastní volba mezi tím nevadí
    _play(user, r[0], "skipped", True, 2)
    with Session(engine) as s:
        skipped, _done, turn = pn._session_signals(s, user)
    assert turn and sum(skipped.values()) == 2


def test_skipped_tracks_are_not_seeds() -> None:
    user = "sess-seed-" + _RUN
    r = _recs(3)
    _play(user, r[1], "skipped", True, 1)
    assert pn._clean_seeds(user, r) == [r[0], r[2]]
    _play(user, r[0], "skipped", True, 1)
    _play(user, r[2], "skipped", True, 1)
    assert pn._clean_seeds(user, r) == [r[2]]  # aspoň poslední, ať je na co navázat
