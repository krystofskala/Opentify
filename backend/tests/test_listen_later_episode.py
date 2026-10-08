"""Na později: epizoda podcastu (převzato z hudby 8. 10.)."""
import uuid

from sqlmodel import Session, select

from app import listen_later
from app.db import engine
from app.models import ListenLater, PodcastEpisode, PodcastShow
from app.routes import podcasts as podcast_routes


def test_episode_later_and_listened_when_finished():
    user = f"u-{uuid.uuid4().hex[:6]}"
    with Session(engine) as s:
        show = PodcastShow(feed_url=f"https://x/{uuid.uuid4().hex}.xml", title="Vinohradská 12")
        s.add(show)
        s.flush()
        ep = PodcastEpisode(show_id=show.id, guid="g", title="Díl 12", audio_url="https://x/a.mp3", duration_ms=600000)
        s.add(ep)
        s.commit()
        ep_id = ep.id
    out = listen_later.add(user, "episode", ep_id, None)
    assert out["episode"]["title"] == "Díl 12" and out["episode"]["showTitle"] == "Vinohradská 12"
    assert listen_later.list_items(user)["active"][0]["kind"] == "episode"
    assert listen_later.mix_candidates(user) == []  # do hudebních mixů ne
    with Session(engine) as s:
        podcast_routes.save_progress(ep_id, podcast_routes.ProgressIn(positionMs=1000, finished=False), session=s, current=(user, "x"))
        podcast_routes.save_progress(ep_id, podcast_routes.ProgressIn(positionMs=599000, finished=True), session=s, current=(user, "x"))
        row = s.exec(select(ListenLater).where(ListenLater.user_id == user)).one()
        assert row.listened_at is not None
