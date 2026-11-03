"""Moje nejposlouchanější: z vlastních poslechů za posledních 30 dní, ne
z ListenBrainz "minulého měsíce" (Kryštof 3. 11.: v listopadu ukazovalo září)."""
import uuid
from datetime import timedelta

from sqlmodel import Session

from app.db import engine
from app.home.generators import my_top_recording_ids
from app.models import Artist, Listen, Recording
from app.utils import utcnow


def test_my_top_counts_last_30_days_and_merges_versions():
    run = uuid.uuid4().hex[:8]
    user = "top-" + run
    now = utcnow().replace(tzinfo=None)
    with Session(engine) as s:
        artist = Artist(name="Top " + run)
        s.add(artist)
        s.commit()
        recs = {}
        for title in ("Hit", "Hit (Remastered 2011)", "Stará", "Jednou", "Přeskočená"):
            recs[title] = Recording(title=title, artist_id=artist.id)
            s.add(recs[title])
        s.commit()

        def listen(title, days_ago, ms=200_000):
            s.add(Listen(user_id=user, recording_id=recs[title].id, played_at=now - timedelta(days=days_ago), duration_played_ms=ms))

        for d in (1, 2, 3):
            listen("Hit", d)
        for d in (4, 5):
            listen("Hit (Remastered 2011)", d)
        for d in (40, 41, 42, 43, 44, 45):  # září: mimo okno
            listen("Stará", d)
        listen("Jednou", 2)  # jeden poslech nestačí
        for d in (1, 2, 3):
            listen("Přeskočená", d, ms=5_000)  # přeskoky se nepočítají
        s.commit()
        hit = recs["Hit"].id

    assert my_top_recording_ids(user) == [hit]
