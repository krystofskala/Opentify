""""Proč tohle?": jemný důvod bez čísel."""
import uuid
from datetime import timedelta

from sqlmodel import Session

from app.db import engine
from app.home.why import reason
from app.models import Artist, Listen, Recording
from app.utils import utcnow

_RUN = uuid.uuid4().hex[:8]


def test_reasons_without_counts():
    user = "why-" + _RUN
    now = utcnow().replace(tzinfo=None)
    with Session(engine) as s:
        a = Artist(name="Why " + _RUN)
        s.add(a)
        s.flush()
        old, fresh, unheard = (Recording(title=t, artist_id=a.id) for t in ("old", "fresh", "unheard"))
        s.add_all([old, fresh, unheard])
        s.flush()
        for d in range(0, 40, 5):  # vrchol před ~3 lety
            s.add(Listen(user_id=user, recording_id=old.id, played_at=now - timedelta(days=1100 + d)))
        s.add(Listen(user_id=user, recording_id=fresh.id, played_at=now - timedelta(days=3)))
        s.commit()
        ids = (old.id, fresh.id, unheard.id)
    r_old, r_fresh, r_unheard = (reason(user, i) for i in ids)
    assert r_old.startswith("Patřila mezi tvé oblíbené v roce")
    assert r_fresh == "Posloucháš ji poslední dobou."
    assert r_unheard.startswith("Od interpreta, kterého posloucháš")
    assert not any(ch.isdigit() for ch in r_fresh)  # žádné sledovací počty
