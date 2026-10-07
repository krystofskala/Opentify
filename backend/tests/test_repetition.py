"""Nabídnuto, nepuštěno (jen to, k čemu přehrávání došlo) a přeskočení
z importu jen v kontextu algoritmu."""

import uuid
from datetime import timedelta

from sqlmodel import Session

from app.db import engine
from app.home import repetition as rp
from app.models import Artist, PlayEvent, RecBatchItem, Recording, Release
from app.utils import utcnow

_RUN = uuid.uuid4().hex[:8]


def _recs(n: int, same_album: bool = False) -> list[str]:
    with Session(engine) as s:
        a = Artist(name="Rep " + uuid.uuid4().hex[:8])
        s.add(a)
        s.flush()
        rel = Release(title="Alb " + uuid.uuid4().hex[:6], artist_id=a.id) if same_album else None
        if rel:
            s.add(rel)
            s.flush()
        recs = []
        for i in range(n):
            if not same_album:
                b = Artist(name=f"Rep {i} " + uuid.uuid4().hex[:8])
                s.add(b)
                s.flush()
            recs.append(Recording(title=f"r{i}", artist_id=a.id if same_album else b.id, release_id=rel.id if rel else None))
        s.add_all(recs)
        s.commit()
        return [r.id for r in recs]


def _batch(user: str, ids: list[str], new: set[str], days_ago: float) -> str:
    bid = uuid.uuid4().hex
    t = (utcnow() - timedelta(days=days_ago)).replace(tzinfo=None)
    with Session(engine) as s:
        for i, rid in enumerate(ids):
            s.add(RecBatchItem(batch_id=bid, user_id=user, recording_id=rid, position=i, slot="new" if rid in new else "familiar", created_at=t))
        s.commit()
    return bid


def _ev(user: str, rid: str, reason: str, days_ago: float, batch: str | None = None, origin: str = "connect") -> None:
    end = (utcnow() - timedelta(days=days_ago)).replace(tzinfo=None)
    with Session(engine) as s:
        s.add(PlayEvent(user_id=user, recording_id=rid, started_at=end - timedelta(seconds=20), ended_at=end,
                        played_ms=20_000, end_reason=reason, rec_batch_id=batch, origin=origin))
        s.commit()


def test_new_offered_twice_and_skipped_pauses_but_unreached_does_not() -> None:
    user = "rep-" + _RUN
    a, b, c, d = _recs(4)
    for days in (5, 2):
        bid = _batch(user, [a, b, c, d], {b, d}, days)
        _ev(user, a, "completed", days, bid)
        _ev(user, b, "skipped", days, bid)
        _ev(user, c, "completed", days, bid)  # d už nehrálo -- ukončil várku
    paused, muted = rp._ignored_offers(user)
    assert b in paused and d not in paused
    assert a not in muted and c not in muted


def test_played_later_lifts_the_pause() -> None:
    user = "rep-later-" + _RUN
    a, b = _recs(2)
    for days in (6, 3):
        bid = _batch(user, [a, b], {b}, days)
        _ev(user, b, "skipped", days, bid)
        _ev(user, a, "completed", days, bid)
    _ev(user, b, "completed", 1)  # pak si ji pustil sám
    paused, _m = rp._ignored_offers(user)
    assert b not in paused


def test_imported_skips_only_in_algorithm_context() -> None:
    user = "rep-imp-" + _RUN
    lone = _recs(1)[0]
    album = _recs(3, same_album=True)
    for days in (20, 10):
        _ev(user, lone, "skipped", days, origin="spotify-history")  # osamocená cizí -> algoritmus
        for i, rid in enumerate(album):  # proklikává album -> vlastní volba
            _ev(user, rid, "skipped", days - i * 0.001, origin="spotify-history")
    skips = rp._imported_skips(user)
    assert lone in skips
    assert not set(album) & skips
