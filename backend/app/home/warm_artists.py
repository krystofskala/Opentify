"""Předehřátí stránek interpretů, které profil poslouchá nejvíc (a oblíbených):
diskografie, Populární, statistiky. Napoprvé se jinak skládají 1-7 s
(MusicBrainz 1 dotaz/s, Deezer a Last.fm limity) -- takhle se otevřou hned.
Denně, po jednom interpretovi s pauzou, ať nebrzdí běžný provoz.
"""

from __future__ import annotations

import asyncio
import logging

from sqlmodel import Session, select

from app.db import engine
from app.home import generators as g
from app.models import FavoriteArtist

logger = logging.getLogger(__name__)

TOP = 30


async def warm_artist_pages() -> int:
    from app.home.personal_mixes import load_taste
    from app.routes.catalog import get_artist_stats, get_discography
    from app.catalog.top_tracks import artist_top_tracks

    user_id = g.home_user()
    taste = await asyncio.to_thread(load_taste, user_id)
    ids = [a for a, _ in taste.artist_weight.most_common(TOP)]
    with Session(engine) as session:
        ids += [f.artist_id for f in session.exec(select(FavoriteArtist).where(FavoriteArtist.user_id == user_id)).all()]
    warmed = 0
    for artist_id in dict.fromkeys(ids):
        try:
            await get_discography(artist_id, None, None)
            await artist_top_tracks(artist_id)
            await get_artist_stats(artist_id, None)
            warmed += 1
        except Exception:  # noqa: BLE001 -- jeden interpret nesmí shodit ostatní
            logger.debug("předehřátí interpreta %s selhalo", artist_id, exc_info=True)
        await asyncio.sleep(1.0)
    return warmed
