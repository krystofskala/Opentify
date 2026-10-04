"""Nový model vkusu (app/home/activation.py): celá historie, stejná váha
poslechu z každého zdroje, max 3 poslechy skladby za den, "bývalé lásky"."""
import uuid
from datetime import datetime, timedelta, timezone

from sqlmodel import Session

from app.db import engine
from app.home import activation as av
from app.models import Artist, Listen, Recording

_RUN = uuid.uuid4().hex[:8]
NOW = datetime(2026, 10, 5, 12, tzinfo=timezone.utc)


def _setup(user, plays):
    """plays: [(název, dní zpět, zdroj)]"""
    with Session(engine) as s:
        artist = Artist(name="Act Artist " + _RUN)
        s.add(artist)
        s.flush()
        recs = {}
        for title, days, source in plays:
            if title not in recs:
                recs[title] = Recording(title=title, artist_id=artist.id, duration_ms=200_000)
                s.add(recs[title])
                s.flush()
            s.add(Listen(user_id=user, recording_id=recs[title].id, played_at=(NOW - timedelta(days=days)).replace(tzinfo=None),
                         duration_played_ms=200_000, source=source))
        s.commit()
        return {t: r.id for t, r in recs.items()}


def test_track_key_ignores_versions_and_feat():
    assert av.track_key("Pink Floyd", "Money - 2011 Remastered") == av.track_key("Pink Floyd", "Money")
    assert av.track_key("Tony Rice & Norman Blake", "Church Street Blues") == av.track_key("Tony Rice", "Church Street Blues (feat. X)")


def test_sources_weigh_the_same_and_daily_cap():
    user = "act-u1-" + _RUN
    ids = _setup(user, [("Spotify", 30, "spotify-history"), ("App", 30, None)] + [("Binge", 30, None)] * 10)
    act = av.compute(user, now=NOW)
    assert abs(act.long[ids["Spotify"]] - act.long[ids["App"]]) < 1e-9
    assert act.total[ids["Binge"]] == 3  # 10 poslechů v jeden den -> počítají se 3


def test_old_favourites_keep_weight_and_former_loves():
    user = "act-u2-" + _RUN
    old = [("Old Love", 900 + d, "spotify-history") for d in range(0, 40, 5)]  # 8 poslechů před ~2,5 lety
    ids = _setup(user, old + [("Now", 2, None)])
    act = av.compute(user, now=NOW)
    assert act.long[ids["Old Love"]] > 0  # celá historie, žádný útes po roce
    assert act.short[ids["Old Love"]] < 1e-6
    assert ids["Old Love"] in act.former_loves()
    assert ids["Now"] not in act.former_loves()
