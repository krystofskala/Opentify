"""Regresní testy oprav z bezpečnostního auditu 5. 10.: cizí playlist se
neobjeví v "Pokračovat v poslechu", cizí rádio relaci nejde přepsat."""
import uuid

from fastapi.testclient import TestClient
from sqlmodel import Session

from app import radio
from app.auth import get_current_user
from app.db import engine
from app.main import app
from app.models import Listen, Playlist, PlaylistKind, Recording
from app.routes.home import _context_item

_RUN = uuid.uuid4().hex[:8]


def test_recent_hides_other_profiles_playlist():
    with Session(engine) as s:
        foreign = Playlist(title="Cizí " + _RUN, owner_user_id="owner-" + _RUN, kind=PlaylistKind.USER)
        mine = Playlist(title="Můj " + _RUN, owner_user_id="me-" + _RUN, kind=PlaylistKind.USER)
        s.add_all([foreign, mine])
        s.commit()
        assert _context_item(s, f"/playlists/{foreign.id}", "me-" + _RUN) is None
        assert _context_item(s, f"/playlists/{mine.id}", "me-" + _RUN)["title"] == "Můj " + _RUN


def test_radio_session_of_another_profile_cannot_be_replaced(monkeypatch):
    with Session(engine) as s:
        rec = Recording(title="R " + _RUN)
        s.add(rec)
        s.commit()
        rid = rec.id
    sid = uuid.uuid4().hex
    # Relace oběti jen v paměti (bez spuštění streamu / ffmpegu).
    radio._sessions[sid] = radio.RadioSession(id=sid, user_id="victim-" + _RUN, device_id="dev", queue=[rid],
                                              start_offset_ms=0.0)
    app.dependency_overrides[get_current_user] = lambda: ("attacker-" + _RUN, "dev2")
    try:
        r = TestClient(app).put(f"/api/v1/radio/{sid}", json={"recordingIds": [rid], "positionMs": 0})
    finally:
        app.dependency_overrides.pop(get_current_user, None)
        radio._sessions.pop(sid, None)
    assert r.status_code == 404
