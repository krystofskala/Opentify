"""Historie poslechu mluveného slova po dnech."""
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

import app.routes.spoken as routes
from app.models import SpokenBook, SpokenFile, SpokenListenDay
from app.spoken import history


def test_listened_ms():
    assert history.listened_ms(None, None, "f1", 5000) == 0           # první uložení
    assert history.listened_ms("f1", 1000, "f1", 16000) == 15000      # běžné uložení
    assert history.listened_ms("f1", 1000, "f1", 900000) == 0         # skok dopředu
    assert history.listened_ms("f1", 9000, "f1", 2000) == 0           # zpět
    assert history.listened_ms("f1", 3000000, "f2", 20000) == 20000   # další díl
    assert history.listened_ms("f1", 3000000, "f2", 999999) == history.MAX_STEP_MS


def test_progress_saves_build_daily_history():
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    with Session(e) as s:
        s.add(SpokenBook(id="b", source_ref="b", release_title="x", title="Krev elfů", author="A. Sapkowski",
                         requested_by_user_id="me"))
        s.add(SpokenFile(id="f1", book_id="b", position=0, path="/x/1.mp3"))
        s.commit()
        for pos in (0, 15000, 30000, 45000):
            routes.save_progress("b", routes.ProgressIn(fileId="f1", positionMs=pos, finished=False), session=s, current=("me", "x"))
        rows = s.exec(select(SpokenListenDay)).all()
        assert len(rows) == 1 and rows[0].seconds == 45 and rows[0].day == history.today()
        out = routes.spoken_history(session=s, current=("me", "x"))
        assert out["totalSeconds"] == 45 and out["days"][0]["items"][0]["title"] == "Krev elfů"
        # Cizí profil nevidí nic.
        assert routes.spoken_history(session=s, current=("other", "x"))["days"] == []
