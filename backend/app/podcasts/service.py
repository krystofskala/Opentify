"""Uložení kanálu a jeho epizod do DB, obnova odebíraných kanálů."""

from __future__ import annotations

import asyncio
import logging
from datetime import timedelta

from sqlmodel import Session, select

from app.db import engine
from app.models import PodcastEpisode, PodcastShow, PodcastSubscription
from app.podcasts import feeds
from app.utils import utcnow

logger = logging.getLogger(__name__)

# Kanál starší než tohle se při otevření / v údržbě načte znovu.
STALE_AFTER = timedelta(hours=1)


def _store(show_id: str, feed: dict) -> None:
    with Session(engine) as session:
        show = session.get(PodcastShow, show_id)
        if show is None:
            return
        show.title = feed["title"]
        show.author = feed["author"] or show.author
        show.description = feed["description"]
        show.artwork_url = feed["artworkUrl"] or show.artwork_url
        show.fetched_at = utcnow()
        show.fetch_error = None
        session.add(show)
        known = {
            e.guid: e for e in session.exec(select(PodcastEpisode).where(PodcastEpisode.show_id == show_id)).all()
        }
        for ep in feed["episodes"]:
            row = known.get(ep["guid"]) or PodcastEpisode(show_id=show_id, guid=ep["guid"], title="", audio_url="")
            row.title = ep["title"]
            row.description = ep["description"]
            row.published_at = ep["publishedAt"] or row.published_at
            row.duration_ms = ep["durationMs"] or row.duration_ms
            row.audio_url = ep["audioUrl"]
            row.artwork_url = ep["artworkUrl"]
            session.add(row)
        session.commit()


def _fail(show_id: str, error: str) -> None:
    with Session(engine) as session:
        show = session.get(PodcastShow, show_id)
        if show is not None:
            show.fetch_error = error[:300]
            show.fetched_at = utcnow()
            session.add(show)
            session.commit()


async def refresh(show_id: str, feed_url: str) -> bool:
    try:
        feed = await feeds.fetch_feed(feed_url)
    except Exception as e:  # noqa: BLE001 -- jeden kanál nesmí shodit ostatní
        logger.warning("podcast %s: RSS nešlo načíst (%s)", feed_url, e)
        await asyncio.to_thread(_fail, show_id, str(e))
        return False
    await asyncio.to_thread(_store, show_id, feed)
    return True


def get_or_create_show(feed_url: str, hint: dict | None = None) -> str:
    with Session(engine) as session:
        show = session.exec(select(PodcastShow).where(PodcastShow.feed_url == feed_url)).first()
        if show is None:
            hint = hint or {}
            show = PodcastShow(
                feed_url=feed_url,
                title=(hint.get("title") or "Podcast")[:500],
                author=hint.get("author"),
                artwork_url=hint.get("artworkUrl"),
                itunes_id=hint.get("itunesId"),
            )
            session.add(show)
            session.commit()
        return show.id


def is_stale(show: PodcastShow) -> bool:
    fetched = show.fetched_at
    if fetched is None:
        return True
    if fetched.tzinfo is None:
        fetched = fetched.replace(tzinfo=utcnow().tzinfo)
    return utcnow() - fetched > STALE_AFTER


async def refresh_subscribed(r) -> int:
    """Údržba (worker): obnovit odebírané kanály -- nové epizody se jen
    ukážou, nic se nestahuje."""
    if not await r.set("podcasts:refresh", "1", nx=True, ex=50 * 60):
        return 0

    def stale_shows() -> list[tuple[str, str]]:
        with Session(engine) as session:
            ids = set(session.exec(select(PodcastSubscription.show_id)).all())
            out = []
            for sid in ids:
                show = session.get(PodcastShow, sid)
                if show is not None and is_stale(show):
                    out.append((show.id, show.feed_url))
            return out

    done = 0
    for show_id, url in await asyncio.to_thread(stale_shows):
        done += await refresh(show_id, url)
    return done
