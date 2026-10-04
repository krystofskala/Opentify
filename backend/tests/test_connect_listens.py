"""Záložní poslechy ze stavu Connect: zapíše se, co opravdu hrálo, přetočení
se nepočítá, a poslech nahlášený appkou se nezdvojí."""
from datetime import datetime, timezone

from sqlmodel import Session, select

import app.connect_listens as cl
from app.db import engine
from app.listens import record_listen
from app.models import Listen, Recording

import uuid

_RUN = uuid.uuid4().hex[:8]


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
        tr.update("cl-user-" + _RUN, "dev", _state(a, i * 15_000))
        t[0] += 15
    # B: přetočeno skoro na konec za 5 s -> nic.
    tr.update("cl-user-" + _RUN, "dev", _state(b, 0))
    t[0] += 5
    tr.update("cl-user-" + _RUN, "dev", _state(b, 190_000))
    t[0] += 5
    tr.update("cl-user-" + _RUN, "dev", _state(c, 0))
    assert _count("cl-user-" + _RUN) == 1


def test_no_duplicate_when_app_reported(monkeypatch):
    t = [2_000_000.0]
    monkeypatch.setattr(cl.time, "time", lambda: t[0])
    tr = cl.ConnectListens()
    a, b = _rec("D", 200_000), _rec("E", 200_000)
    tr.update("cl-user2-" + _RUN, "dev", _state(a, 0))
    # Appka sama nahlásí (začátek o pár sekund jinak).
    record_listen("cl-user2-" + _RUN, a, played_at=datetime.fromtimestamp(t[0] + 3, tz=timezone.utc), duration_played_ms=100_000)
    for _ in range(9):
        t[0] += 15
        tr.update("cl-user2-" + _RUN, "dev", _state(a, int((t[0] - 2_000_000.0) * 1000)))
    tr.update("cl-user2-" + _RUN, "dev", _state(b, 0))
    assert _count("cl-user2-" + _RUN) == 1


def test_play_events_record_how_each_play_ended(monkeypatch):
    from app.models import PlayEvent, Playlist, PlaylistKind

    user = "cl-user4-" + _RUN
    t = [4_000_000.0]
    monkeypatch.setattr(cl.time, "time", lambda: t[0])
    with Session(engine) as s:
        s.add(Playlist(title="Denní mix 1 " + _RUN, owner_user_id=user, kind=PlaylistKind.PERSONAL_MIX))
        s.commit()
    tr = cl.ConnectListens()
    done, skipped, mid = _rec("P", 60_000), _rec("Q", 200_000), _rec("R", 200_000)

    def st(rid, pos, dur):
        return {**_state(rid, pos, dur=dur), "sourceLabel": "Denní mix 1 " + _RUN}

    for i in range(5):  # P dohraje (60 s)
        tr.update(user, "dev", st(done, i * 15_000, 60_000))
        t[0] += 15
    tr.update(user, "dev", st(skipped, 0, 200_000))
    t[0] += 5
    tr.update(user, "dev", st(mid, 0, 200_000))  # Q přeskočena po 5 s
    for i in range(1, 5):
        t[0] += 15
        tr.update(user, "dev", st(mid, i * 15_000, 200_000))
    tr.update(user, "dev", {"nowPlaying": None, "isPlaying": False})  # R zastavena v půlce
    with Session(engine) as s:
        rows = {e.recording_id: e for e in s.exec(select(PlayEvent).where(PlayEvent.user_id == user)).all()}
    assert rows[done].end_reason == "completed"
    assert rows[skipped].end_reason == "skipped"
    assert rows[mid].end_reason == "stopped"
    assert all(e.algorithmic and e.playlist_id for e in rows.values())


def test_skip_twice_in_a_row_then_reset_by_listen(monkeypatch):
    from app.models import SkipStreak

    t = [3_000_000.0]
    monkeypatch.setattr(cl.time, "time", lambda: t[0])
    tr = cl.ConnectListens()
    x, other = _rec("X", 200_000), _rec("Y", 200_000)

    def play_and_skip():
        tr.update("cl-user3-" + _RUN, "dev", _state(x, 0))
        t[0] += 5
        tr.update("cl-user3-" + _RUN, "dev", _state(other, 0))  # po 5 s jiná skladba
        t[0] += 5
        tr.update("cl-user3-" + _RUN, "dev", {"nowPlaying": None, "isPlaying": False})

    def streak():
        with Session(engine) as s:
            row = s.get(SkipStreak, ("cl-user3-" + _RUN, x))
            return row.streak if row else 0

    play_and_skip()
    assert streak() == 1
    play_and_skip()
    assert streak() == 2
    record_listen("cl-user3-" + _RUN, x, duration_played_ms=150_000)
    assert streak() == 0
