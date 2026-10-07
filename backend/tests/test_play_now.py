"""Pusť teď / nekonečné hraní: známé skladby podle vlastní historie, bez
právě zahraných, nekonečné hraní navazuje na interprety semínka."""
import asyncio
import random
import uuid
from collections import Counter
from datetime import timedelta

from sqlmodel import Session

from app.db import engine
from app.home import play_now as pn
from app.models import Artist, Listen, Recording
from app.utils import utcnow

_RUN = uuid.uuid4().hex[:8]


def _setup(user):
    now = utcnow().replace(tzinfo=None)
    ids = {}
    with Session(engine) as s:
        for name in ("Bluegrass Band", "Folk Duo", "Metal Act"):
            artist = Artist(name=f"{name} {_RUN}")
            s.add(artist)
            s.flush()
            for n in range(4):
                rec = Recording(title=f"{name} song {n}", artist_id=artist.id, duration_ms=200_000)
                s.add(rec)
                s.flush()
                ids[(name, n)] = rec.id
        # Bluegrass a Folk se poslouchají spolu (stejné večery), Metal jindy.
        for day in range(1, 30, 2):
            base = now - timedelta(days=day)
            for n in range(4):
                s.add(Listen(user_id=user, recording_id=ids[("Bluegrass Band", n)], played_at=base + timedelta(minutes=4 * n),
                             duration_played_ms=200_000))
                s.add(Listen(user_id=user, recording_id=ids[("Folk Duo", n)], played_at=base + timedelta(minutes=20 + 4 * n),
                             duration_played_ms=200_000))
                s.add(Listen(user_id=user, recording_id=ids[("Metal Act", n)], played_at=base - timedelta(hours=10, minutes=4 * n),
                             duration_played_ms=200_000))
        s.commit()
    return ids


def test_endless_follows_seed_and_skips_played(monkeypatch):
    user = "pn-u1-" + _RUN
    ids = _setup(user)
    pn._cache.clear()
    seed = ids[("Bluegrass Band", 0)]
    played = [ids[("Bluegrass Band", 1)]]
    familiar, _new_seeds, reason = pn.pick(user, [seed], played, 2, random.Random(1))
    assert seed not in familiar and played[0] not in familiar
    names = set()
    with Session(engine) as s:
        for rid in familiar:
            names.add(s.get(Artist, s.get(Recording, rid).artist_id).name)
    # Navazuje na semínko a na to, co se pouští spolu s ním -- metal ne na prvních místech.
    assert names and all("Metal" not in n for n in names)
    assert reason.startswith("Navazuje")


def test_same_song_in_another_version_does_not_repeat():
    user = "pn-u3-" + _RUN
    ids = _setup(user)
    with Session(engine) as s:
        other = Artist(name="Other Version " + _RUN)
        s.add(other)
        s.flush()
        twin = Recording(title="Bluegrass Band song 1 (Live)", artist_id=other.id, duration_ms=200_000)
        s.add(twin)
        s.flush()
        for d in range(1, 20, 2):
            s.add(Listen(user_id=user, recording_id=twin.id, played_at=(utcnow() - timedelta(days=d)).replace(tzinfo=None),
                         duration_played_ms=200_000))
        s.commit()
        twin_id = twin.id
    pn._cache.clear()
    familiar, _s, _r = pn.pick(user, [ids[("Bluegrass Band", 0)]], [ids[("Bluegrass Band", 1)]], 6, random.Random(3))
    assert twin_id not in familiar


def test_mood_prefers_fitting_artists():
    user = "pn-u4-" + _RUN
    ids = _setup(user)
    pn._cache.clear()
    act = pn._activation(user)
    metal = act.artist_of[ids[("Metal Act", 0)]]
    others = {a for a in act.artist_of.values() if a != metal}
    moods = {metal: 1.0, **{a: 0.0 for a in others}}
    familiar, _s, reason = pn.pick(user, [], [], 2, random.Random(5), "energie", moods)
    assert reason.startswith("Energie")
    assert act.artist_of[familiar[0]] == metal  # náladě sedící interpret první


def test_next_chunk_without_network(monkeypatch):
    _no_prefetch(monkeypatch)
    user = "pn-u2-" + _RUN
    _setup(user)
    pn._cache.clear()

    async def no_similar(*_a, **_k):
        return []

    from app.home import lastfm_taste as lt

    monkeypatch.setattr(lt, "similar_track_ids", no_similar)
    out = asyncio.run(pn.next_chunk(user, [], [], 5))
    assert 1 <= len(out["recordingIds"]) <= 5
    assert len(set(out["recordingIds"])) == len(out["recordingIds"])


def test_new_profile_continues_from_first_listens(monkeypatch):
    """Nový profil: poslechy jen z poslední hodiny (ty se ze známých
    vynechávají) -> nové navážou na ně, ne prázdná várka."""
    user = "pn-new-" + _RUN
    _no_prefetch(monkeypatch)
    now = utcnow().replace(tzinfo=None)
    with Session(engine) as s:
        heard_artist = Artist(name="Heard " + _RUN)
        fresh_artist = Artist(name="Fresh " + _RUN)
        s.add(heard_artist)
        s.add(fresh_artist)
        s.flush()
        heard = Recording(title="First song", artist_id=heard_artist.id, duration_ms=200_000)
        fresh = [Recording(title=f"Fresh {n}", artist_id=fresh_artist.id, duration_ms=200_000) for n in range(3)]
        s.add(heard)
        s.add_all(fresh)
        s.flush()
        s.add(Listen(user_id=user, recording_id=heard.id, played_at=now - timedelta(minutes=10), duration_played_ms=200_000))
        s.commit()
        heard_id, fresh_ids = heard.id, [r.id for r in fresh]
    pn._cache.clear()
    asked: list = []

    async def similar(seeds, exclude, rng, n):
        asked.append(list(seeds))
        return fresh_ids

    from app.home import lastfm_taste as lt

    monkeypatch.setattr(lt, "similar_track_ids", similar)
    out = asyncio.run(pn.next_chunk(user, [], [], 8))
    assert asked and asked[0] == [heard_id]
    assert out["recordingIds"] and set(out["recordingIds"]) <= set(fresh_ids)
    assert out["reason"] == "Navazuje na First song"


def _no_prefetch(monkeypatch):
    async def nothing(*_a, **_k):
        return None

    monkeypatch.setattr(pn, "_prefetch", nothing)


def _artist_of(rid):
    with Session(engine) as s:
        return s.get(Artist, s.get(Recording, rid).artist_id).name


def test_session_cap_mutes_artist_played_a_lot():
    user = "pn-cap-" + _RUN
    ids = _setup(user)
    pn._cache.clear()
    pn._batches.clear()
    act = pn._activation(user)
    blue = act.artist_of[ids[("Bluegrass Band", 0)]]
    hits = 0
    for seed in range(20):
        fam, _s, _r = pn.pick(user, [], [], 2, random.Random(seed), session_counts=Counter({blue: 3}))
        hits += sum(1 for r in fam if act.artist_of.get(r) == blue)
    assert hits <= 2  # 0,3^3 ~ 3 % -- skoro nikdy


def test_endless_keeps_one_seed_artist_track_even_when_capped():
    user = "pn-seed-" + _RUN
    ids = _setup(user)
    pn._cache.clear()
    act = pn._activation(user)
    seed = ids[("Metal Act", 0)]
    metal = act.artist_of[seed]
    fam, _s, _r = pn.pick(user, [seed], [seed], 3, random.Random(1), session_counts=Counter({metal: 2}))
    assert any(act.artist_of.get(r) == metal for r in fam)


def test_second_tap_gives_a_different_batch():
    user = "pn-mem-" + _RUN
    _setup(user)
    pn._cache.clear()
    pn._batches.clear()
    first, _s, _r = pn.pick(user, [], [], 4, random.Random(7))
    pn._remember_batch(user, first)
    second, _s, _r = pn.pick(user, [], [], 4, random.Random(7))
    assert len(set(first) & set(second)) <= 1


def test_safe_start_puts_downloaded_first():
    assert pn._safe_start(["a", "b", "c", "d"], {"c", "d"}) == ["c", "d", "a", "b"]
    assert pn._safe_start(["a", "b", "c"], {"a"}) == ["a", "b", "c"]
    assert pn._safe_start(["a", "b"], set()) == ["a", "b"]


def test_band_links_group_solo_project_with_band(monkeypatch):
    import json

    import app.redis_bus as bus
    from app.catalog.cache import CACHE_PREFIX

    with Session(engine) as s:
        band = Artist(name="Band " + _RUN, mbid="mb-band-" + _RUN)
        solo = Artist(name="Solo " + _RUN, mbid="mb-solo-" + _RUN)
        s.add(band)
        s.add(solo)
        s.commit()
        band_id, solo_id = band.id, solo.id

    class FakeRedis:
        async def mget(self, keys):
            out = []
            for k in keys:
                if k == CACHE_PREFIX + f"mb:artist:mb-solo-{_RUN}":
                    out.append(json.dumps({"relations": [{"type": "member of band", "artist": {"id": f"mb-band-{_RUN}"}}]}))
                else:
                    out.append(None)
            return out

    monkeypatch.setattr(bus, "get_redis", lambda: FakeRedis())
    links = asyncio.run(pn._band_links([solo_id, band_id]))
    assert links.get(solo_id) == {band_id}


def test_new_tracks_obey_filters_and_title_key(monkeypatch):
    """Nové skladby: neoblíbený interpret ven, stejná píseň jinde ven."""
    user = "pn-newf-" + _RUN
    ids = _setup(user)
    _no_prefetch(monkeypatch)
    now = utcnow().replace(tzinfo=None)
    with Session(engine) as s:
        ok_artist = Artist(name="Fresh Ok " + _RUN)
        bad_artist = Artist(name="Fresh Banned " + _RUN)
        cover_artist = Artist(name="Cover " + _RUN)
        s.add_all([ok_artist, bad_artist, cover_artist])
        s.flush()
        ok = Recording(title="Brand New Tune", artist_id=ok_artist.id, duration_ms=1000)
        bad = Recording(title="Other Tune", artist_id=bad_artist.id, duration_ms=1000)
        cover = Recording(title="Bluegrass Band song 0", artist_id=cover_artist.id, duration_ms=1000)
        s.add_all([ok, bad, cover])
        s.commit()
        cand = [ok.id, bad.id, cover.id]
        bad_aid = bad_artist.id
    pn._cache.clear()
    pn._batches.clear()

    async def similar(seeds, exclude, rng, n):
        return cand

    from app.home import lastfm_taste as lt
    import app.library.dislikes as dislikes

    monkeypatch.setattr(lt, "similar_track_ids", similar)
    monkeypatch.setattr(dislikes, "disliked_artist_ids", lambda _s, _u: {bad_aid})
    seed = ids[("Bluegrass Band", 0)]
    out = asyncio.run(pn.next_chunk(user, [seed], [seed], 8))
    assert cand[0] in out["recordingIds"]
    assert cand[1] not in out["recordingIds"]  # neoblíbený
    assert cand[2] not in out["recordingIds"]  # tatáž píseň (semínko) jinde


def test_clean_start_uses_likes_and_diverse_seeds(monkeypatch):
    """Čistý start: 1 poslech + srdíčka od jiných interpretů -> srdíčka jako
    známé, semínka pro nové z různých interpretů, víc nového."""
    from app.library.spotify_import import get_or_create_liked_songs_playlist
    from app.models import PlaylistItem

    user = "pn-clean-" + _RUN
    now = utcnow().replace(tzinfo=None)
    with Session(engine) as s:
        artists = [Artist(name=f"Clean {i} {_RUN}") for i in range(4)]
        s.add_all(artists)
        s.flush()
        recs = [Recording(title=f"clean song {i}", artist_id=artists[i].id, duration_ms=200_000) for i in range(4)]
        s.add_all(recs)
        s.flush()
        s.add(Listen(user_id=user, recording_id=recs[0].id, played_at=now - timedelta(minutes=5), duration_played_ms=200_000))
        liked = get_or_create_liked_songs_playlist(s, user)
        for pos, r in enumerate(recs[1:]):
            s.add(PlaylistItem(playlist_id=liked.id, recording_id=r.id, position=pos))
        s.commit()
        ids = [r.id for r in recs]
    pn._cache.clear()
    pn._batches.clear()
    fam, new_seeds, _reason = pn.pick(user, [], [], 8, random.Random(3))
    assert set(fam) <= set(ids[1:]) and fam  # srdíčka jako známé (poslech z poslední hodiny ne)
    assert len(new_seeds) >= 2
    with Session(engine) as s:
        seed_artists = {s.get(Recording, r).artist_id for r in new_seeds}
    assert len(seed_artists) == len(new_seeds)  # každé semínko od jiného interpreta
