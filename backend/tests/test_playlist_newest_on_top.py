"""Playlist: nově přidaná skladba jde nahoru (Kryštof 24. 10.)."""

import uuid

from fastapi.testclient import TestClient
from sqlmodel import Session, select

from app.auth import get_current_user
from app.db import engine
from app.main import app
from app.models import Artist, Playlist, PlaylistItem, Recording


def test_added_song_goes_on_top() -> None:
    user = "pl-top-" + uuid.uuid4().hex[:6]
    with Session(engine) as s:
        a = Artist(name="A " + user)
        s.add(a)
        s.flush()
        recs = [Recording(title=f"T{i}", artist_id=a.id) for i in range(3)]
        s.add_all(recs)
        p = Playlist(owner_user_id=user, title="P")
        s.add(p)
        s.commit()
        ids, pid = [r.id for r in recs], p.id
    app.dependency_overrides[get_current_user] = lambda: (user, "dev")
    try:
        client = TestClient(app)
        for rid in ids:
            assert client.post(f"/api/v1/playlists/{pid}/items", json={"recording_id": rid}).status_code == 200
    finally:
        app.dependency_overrides.pop(get_current_user, None)
    with Session(engine) as s:
        order = [i.recording_id for i in s.exec(
            select(PlaylistItem).where(PlaylistItem.playlist_id == pid).order_by(PlaylistItem.position)
        ).all()]
    assert order == ids[::-1]
