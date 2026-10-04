"""Balíček "Údaje o účtu" (StreamingHistory_music_*.json): přečte se jako
historie posledního roku a nahradí jen to období -- starší poslechy z
rozšířené historie zůstanou."""
import io
import json
import uuid
import zipfile

from sqlmodel import Session, select

from app.db import engine
from app.library import spotify_history as sh
from app.models import Listen

_RUN = uuid.uuid4().hex[:8]


def _zip(files: dict[str, object]) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        for name, data in files.items():
            zf.writestr(name, json.dumps(data))
    return buf.getvalue()


def test_reads_account_data_music_only():
    raw = _zip({
        "Spotify Account Data/StreamingHistory_music_0.json": [
            {"endTime": "2026-05-01 10:00", "artistName": "A " + _RUN, "trackName": "T1", "msPlayed": 200000},
            {"endTime": "2026-05-01 10:05", "artistName": "Unknown Artist", "trackName": "Unknown Track", "msPlayed": 1},
        ],
        "Spotify Account Data/StreamingHistory_podcast_0.json": [{"endTime": "2026-05-01 11:00", "podcastName": "P"}],
        "Spotify Account Data/Playlist1.json": {"playlists": []},
    })
    plays = sh.read_zip(raw)
    assert len(plays) == 1
    assert plays[0]["ts"] == "2026-05-01T10:00:00Z" and plays[0]["account"]


def test_account_import_keeps_older_extended_listens(monkeypatch):
    monkeypatch.setattr(sh, "build_year_playlists", lambda user_id: {})
    user = "acc-" + _RUN
    old = [{"ts": "2019-03-01T10:00:00Z", "ms": 200000, "track": "Old", "artist": "Acc " + _RUN, "album": None,
            "spotify_id": None, "reason_end": "trackdone", "skipped": False}]
    sh.import_history(user, old)
    new = [{"ts": "2026-05-01T10:00:00Z", "ms": 200000, "track": "New", "artist": "Acc " + _RUN, "album": None,
            "spotify_id": None, "account": True}]
    sh.import_history(user, new)
    sh.import_history(user, new)  # opakovaně nezdvojí
    with Session(engine) as s:
        years = sorted(lis.played_at.year for lis in s.exec(select(Listen).where(Listen.user_id == user)).all())
    assert years == [2019, 2026]
