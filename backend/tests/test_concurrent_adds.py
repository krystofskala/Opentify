"""Souběžná přidání nic nezdvojí (simulace 5. 10.: "Na později" 3× z 5 klepnutí)."""
import uuid
from concurrent.futures import ThreadPoolExecutor

from sqlmodel import Session, func, select

from app import listen_later
from app.db import engine
from app.models import ListenLater, Recording

_RUN = uuid.uuid4().hex[:8]


def test_listen_later_parallel_adds_once():
    user = "conc-" + _RUN
    with Session(engine) as s:
        rec = Recording(title="C " + _RUN)
        s.add(rec)
        s.commit()
        rid = rec.id
    with ThreadPoolExecutor(max_workers=5) as pool:
        list(pool.map(lambda _: listen_later.add(user, "track", rid, None), range(5)))
    with Session(engine) as s:
        n = s.exec(select(func.count()).select_from(ListenLater).where(ListenLater.user_id == user)).one()
    assert n == 1
