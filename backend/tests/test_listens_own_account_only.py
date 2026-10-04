"""Poslechy jiného profilu se NIKDY neodešlou na adminův ListenBrainz ani
Last.fm (uživatel 4. 10. 2026): bez vlastního tokenu se neposílají vůbec,
s vlastním jen do vlastního účtu."""
import asyncio
import uuid

from sqlmodel import Session

from app import lastfm_scrobble, listens
from app.auth import ADMIN_ID
from app.db import engine
from app.models import AppUser, Artist, Listen, Recording

_RUN = uuid.uuid4().hex[:8]


def _listen(user_id):
    with Session(engine) as s:
        artist = Artist(name="Own Acc " + _RUN)
        s.add(artist)
        s.flush()
        rec = Recording(title="Song " + _RUN, artist_id=artist.id, duration_ms=200_000)
        s.add(rec)
        s.flush()
        s.add(Listen(user_id=user_id, recording_id=rec.id, duration_played_ms=200_000))
        s.commit()


def test_other_profile_without_token_sends_nothing(monkeypatch):
    other = "own-acc-" + _RUN
    monkeypatch.setenv("LISTENBRAINZ_TOKEN", "ADMIN-TOKEN")
    assert listens.token_for(other) is None
    assert listens.token_for(ADMIN_ID) is not None  # admin smí svůj z .env
    _listen(other)
    calls = []

    async def spy(user_id, token):
        calls.append((user_id, token))
        return 0

    monkeypatch.setattr(listens, "_submit_for", spy)
    asyncio.run(listens.submit_pending())
    assert all(not (uid == other) for uid, _t in calls)


def test_other_profile_with_own_token_uses_only_own(monkeypatch):
    other = "own-acc2-" + _RUN
    with Session(engine) as s:
        s.add(AppUser(id=other, username="u" + _RUN, name="Test", listenbrainz_token="OWN-TOKEN"))
        s.commit()
    monkeypatch.setenv("LISTENBRAINZ_TOKEN", "ADMIN-TOKEN")
    assert listens.token_for(other) == "OWN-TOKEN"
    _listen(other)
    calls = []

    async def spy(user_id, token):
        calls.append((user_id, token))
        return 0

    monkeypatch.setattr(listens, "_submit_for", spy)
    asyncio.run(listens.submit_pending())
    assert (other, "OWN-TOKEN") in calls
    assert all(t != "ADMIN-TOKEN" for uid, t in calls if uid != ADMIN_ID)


def test_lastfm_scrobbles_only_profiles_with_own_session(monkeypatch):
    other = "own-acc3-" + _RUN
    _listen(other)
    calls = []

    async def spy(user_id, sk, since):
        calls.append((user_id, sk))
        return 0

    monkeypatch.setattr(lastfm_scrobble, "_submit_for", spy)
    asyncio.run(lastfm_scrobble.submit_pending())
    assert all(uid != other for uid, _sk in calls)  # bez vlastního Last.fm nic
