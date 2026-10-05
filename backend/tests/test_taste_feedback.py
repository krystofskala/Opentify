""""Víc / míň takových": kroky ±5, strop ±15, projeví se ve vkusu."""
import uuid

from fastapi.testclient import TestClient
from sqlmodel import Session

from app.auth import get_current_user
from app.db import engine
from app.home import feedback
from app.main import app
from app.models import Artist, Recording

_RUN = uuid.uuid4().hex[:8]


def test_steps_and_limit():
    user = "fb-" + _RUN
    for _ in range(5):
        d = feedback.set_feedback(user, "artist-x", "more")
    assert d == feedback.LIMIT
    assert feedback.set_feedback(user, "artist-x", "less") == feedback.LIMIT - feedback.STEP
    feedback.clear(user, "artist-x")
    assert feedback.deltas(user) == {}
    assert feedback.fit_multiplier(-15) == 0.05 and feedback.fit_multiplier(10) == 2.0


def test_endpoint_by_recording():
    with Session(engine) as s:
        a = Artist(name="FB " + _RUN)
        s.add(a)
        s.flush()
        r = Recording(title="t", artist_id=a.id)
        s.add(r)
        s.commit()
        rid, aid = r.id, a.id
    user = "fb2-" + _RUN
    app.dependency_overrides[get_current_user] = lambda: (user, "dev")
    try:
        c = TestClient(app)
        assert c.post("/api/v1/home/feedback", json={"direction": "less", "recordingId": rid}).json() == {"artistId": aid, "delta": -5.0}
        assert c.get("/api/v1/home/feedback").json() == {"artists": {aid: -5.0}}
        assert c.post("/api/v1/home/feedback", json={"direction": "sideways", "artistId": aid}).status_code == 400
        c.delete(f"/api/v1/home/feedback/{aid}")
        assert c.get("/api/v1/home/feedback").json() == {"artists": {}}
    finally:
        app.dependency_overrides.pop(get_current_user, None)
