"""Sdílená mezipaměť vkusu: poslech ji nezahodí, výslovná volba ano."""

import uuid

from sqlmodel import Session

from app.db import engine
from app.home import taste_cache
from app.models import Artist, FavoriteArtist


def test_cache_reused_until_explicit_choice() -> None:
    user = "tc-" + uuid.uuid4().hex[:8]
    calls = []

    def build():
        calls.append(1)
        return len(calls)

    assert taste_cache.get("x", user, build) == 1
    assert taste_cache.get("x", user, build) == 1  # z mezipaměti
    with Session(engine) as s:
        a = Artist(name="Fav " + user)
        s.add(a)
        s.flush()
        s.add(FavoriteArtist(user_id=user, artist_id=a.id))
        s.commit()
    assert taste_cache.get("x", user, build) == 2  # oblíbený interpret -> znovu
    taste_cache.invalidate(user)
    assert taste_cache.get("x", user, build) == 3
