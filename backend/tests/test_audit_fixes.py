"""Tiché opravy po auditu 7. 10. (opentify-notes/recommendation-research/
10-audit-po-zmenach-2026-10-07.md): poslech z várky = algoritmus, jedna
výslovná volba, společný filtr nových, "tatáž píseň" s interpretem."""

import uuid
from datetime import timedelta

from sqlmodel import Session

from app.db import engine
from app.home import activation as av
from app.home import novelty, taste_cache
from app.home.play_now import _song_key
from app.models import (
    Artist, ArtistFeedback, FavoriteArtist, Listen, PlayEvent, Playlist, PlaylistItem, PlaylistKind, Recording,
)
from app.utils import utcnow


def _rec(title: str, artist_name: str | None = None) -> tuple[str, str]:
    with Session(engine) as s:
        a = Artist(name=(artist_name or "A") + " " + uuid.uuid4().hex[:8])
        s.add(a)
        s.flush()
        r = Recording(title=title, artist_id=a.id)
        s.add(r)
        s.commit()
        return r.id, a.id


def test_endless_listen_under_album_label_counts_as_algorithm() -> None:
    user = "af-endless-" + uuid.uuid4().hex[:8]
    rid, _a = _rec("Endless track")
    t = (utcnow() - timedelta(hours=1)).replace(tzinfo=None)
    with Session(engine) as s:
        # Klient nese název alba, odkud se navázalo; přehrání patří do várky.
        s.add(Listen(user_id=user, recording_id=rid, played_at=t, source="Hybrid Theory"))
        s.add(PlayEvent(user_id=user, recording_id=rid, started_at=t, ended_at=t + timedelta(minutes=3),
                        end_reason="completed", rec_batch_id="b1", origin="connect"))
        s.commit()
    act = av.compute(user)
    assert act.timeline_algo == [True]


def test_one_explicit_definition_without_shared_playlists() -> None:
    owner = "af-own-" + uuid.uuid4().hex[:8]
    other = "af-other-" + uuid.uuid4().hex[:8]
    mine, a_mine = _rec("Mine")
    theirs, a_theirs = _rec("Theirs")
    _r, a_fav = _rec("Fav")
    with Session(engine) as s:
        p = Playlist(owner_user_id=owner, title="Moje", kind=PlaylistKind.USER)
        q = Playlist(owner_user_id=other, title="Cizí", kind=PlaylistKind.USER)
        s.add_all([p, q])
        s.flush()
        s.add_all([PlaylistItem(playlist_id=p.id, recording_id=mine, position=0),
                   PlaylistItem(playlist_id=q.id, recording_id=theirs, position=0),
                   FavoriteArtist(user_id=owner, artist_id=a_fav)])
        s.commit()
    explicit = av.explicit_artists(owner)
    assert a_mine in explicit and a_fav in explicit and a_theirs not in explicit


def test_common_new_filter_drops_heard_under_other_id_and_muted() -> None:
    user = "af-new-" + uuid.uuid4().hex[:8]
    heard, a1 = _rec("Same Song", "Band")
    with Session(engine) as s:
        art = s.get(Artist, a1)
        dup = Recording(title="Same Song (Remastered 2011)", artist_id=art.id)
        s.add(dup)
        s.add(Listen(user_id=user, recording_id=heard, played_at=(utcnow() - timedelta(days=3)).replace(tzinfo=None)))
        s.commit()
        dup_id = dup.id
    muted_track, muted_artist = _rec("Muted")
    fresh, _a = _rec("Fresh")
    with Session(engine) as s:
        s.add(ArtistFeedback(user_id=user, artist_id=muted_artist, delta=-10))
        s.commit()
    taste_cache.invalidate(user)
    assert novelty.filter_new(user, [dup_id, muted_track, fresh]) == [fresh]


def test_song_key_generic_titles_need_artist() -> None:
    assert _song_key("a1", "Salt Creek") == _song_key("a2", "Salt Creek")  # tatáž píseň, jiná verze
    assert _song_key("a1", "Intro") != _song_key("a2", "Intro")  # různé písně


def test_algorithm_counts_a_third_in_long_profile_for_any_profile() -> None:
    user = "af-long-" + uuid.uuid4().hex[:8]
    own, _a = _rec("Own pick")
    algo, _b = _rec("Algo pick")
    t = (utcnow() - timedelta(days=10)).replace(tzinfo=None)
    with Session(engine) as s:
        s.add(Listen(user_id=user, recording_id=own, played_at=t, source="Výsledky hledání"))
        s.add(Listen(user_id=user, recording_id=algo, played_at=t, source="Pusť teď"))
        s.commit()
    act = av.compute(user)
    assert abs(act.long[algo] - act.long[own] * av.ALGO_DAY) < 1e-9
    assert abs(act.short[algo] - act.short[own]) < 1e-9  # co posloucháš teď: plně


def test_not_counted_in_taste_track_and_playlist() -> None:
    import asyncio

    from app.routes import home as routes

    async def nothing(_u):
        return None

    import app.home.service as svc

    orig = svc.invalidate_home_cache_for
    svc.invalidate_home_cache_for = nothing
    try:
        user = "af-ex-" + uuid.uuid4().hex[:8]
        a, _x = _rec("For a friend")
        b, _y = _rec("Lullaby")
        c, _z = _rec("Mine")
        t = (utcnow() - timedelta(days=2)).replace(tzinfo=None)
        with Session(engine) as s:
            s.add(Listen(user_id=user, recording_id=a, played_at=t))
            s.add(Listen(user_id=user, recording_id=b, played_at=t, context="/playlists/pl-sleep"))
            s.add(Listen(user_id=user, recording_id=c, played_at=t))
            s.commit()
        asyncio.run(routes.set_taste_exclusion(routes.TasteExclusionIn(kind="recording", id=a, excluded=True), current=(user, "d")))
        out = asyncio.run(routes.set_taste_exclusion(routes.TasteExclusionIn(kind="playlist", id="pl-sleep", excluded=True), current=(user, "d")))
        assert out == {"recordings": [a], "playlists": ["pl-sleep"]}
        assert set(av.compute(user).total) == {c}
    finally:
        svc.invalidate_home_cache_for = orig


def test_deferred_new_track_waits_for_next_batch() -> None:
    from app.home import play_now as pn

    user = "af-def-" + uuid.uuid4().hex[:8]
    pn._remember_deferred(user, ["x"], set())
    assert pn._take_deferred(user) == ["x"]
    pn._remember_deferred(user, ["x"], set())
    pn._remember_deferred(user, ["x"], set())  # potřetí odložená -> už nečeká
    assert pn._take_deferred(user) == []
    pn._remember_deferred(user, ["y"], set())
    pn._remember_deferred(user, [], {"y"})  # nabídnutá -> nečeká
    assert pn._take_deferred(user) == []
