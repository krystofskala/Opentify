"""Stejná skladba v jiné verzi jen jednou v mixu (14. 10.)."""
import uuid

from sqlmodel import Session

from app.db import engine
from app.home.generators import _drop_version_twins
from app.models import Artist, Recording

_RUN = uuid.uuid4().hex[:6]


def test_zivak_a_jina_velikost_pismen_vypadnou():
    with Session(engine) as s:
        a = Artist(name="Willie " + _RUN)
        b = Artist(name="Jiný " + _RUN)
        s.add_all([a, b])
        s.flush()
        recs = [
            Recording(title="On the Road Again", artist_id=a.id),
            Recording(title="On the Road Again - Live", artist_id=a.id),
            Recording(title="on the road again (Live at The Hollywood Bowl)", artist_id=a.id),
            Recording(title="On the Road Again", artist_id=b.id),
            Recording(title="Whiskey River", artist_id=a.id),
        ]
        s.add_all(recs)
        s.commit()
        ids = [r.id for r in recs]
        out = _drop_version_twins(s, ids)
    assert out == [ids[0], ids[3], ids[4]]
