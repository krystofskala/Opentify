"""Pusť teď / nekonečné hraní: známé skladby podle vlastní historie, bez
právě zahraných, nekonečné hraní navazuje na interprety semínka."""
import asyncio
import random
import uuid
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
