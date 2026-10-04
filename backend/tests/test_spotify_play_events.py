"""Import historie ze Spotify zapíše i to, jak přehrání skončila (PlayEvent),
jen pro skladby, které profil opravdu poslouchal, a poslechy nemění."""
import uuid

from sqlmodel import Session, select

from app.db import engine
from app.library import spotify_history as sh
from app.models import PlayEvent

_RUN = uuid.uuid4().hex[:8]


def _play(track, ms, reason, skipped=False, ts="2024-05-01T10:00:00Z"):
    return {"ts": ts, "ms": ms, "track": track, "artist": "PE Artist " + _RUN, "album": None,
            "spotify_id": None, "reason_end": reason, "skipped": skipped}


def test_end_reasons():
    assert sh._end_reason(_play("a", 200_000, "trackdone")) == "completed"
    assert sh._end_reason(_play("a", 5_000, "fwdbtn")) == "skipped"
    assert sh._end_reason(_play("a", 90_000, "fwdbtn")) == "next"
    assert sh._end_reason(_play("a", 90_000, "logout")) == "stopped"
    assert sh._end_reason(_play("a", 90_000, None, skipped=True)) == "skipped"
    assert sh._end_reason({"ts": "x", "ms": 1, "track": "a", "artist": "b"}) is None  # YT Music


def test_import_play_events_only_for_listened_tracks():
    user = "pe-user-" + _RUN
    plays = [
        _play("Loved", 200_000, "trackdone"),
        _play("Loved", 4_000, "fwdbtn", ts="2024-05-02T10:00:00Z"),
        _play("Only skipped", 3_000, "fwdbtn"),  # nikdy neposlouchaná -> nic
    ]
    assert sh.import_play_events(user, plays) == 2
    assert sh.import_play_events(user, plays) == 2  # opakovaně nezdvojí
    with Session(engine) as s:
        rows = s.exec(select(PlayEvent).where(PlayEvent.user_id == user)).all()
    assert sorted(r.end_reason for r in rows) == ["completed", "skipped"]
    assert all(r.origin == sh.SOURCE for r in rows)
