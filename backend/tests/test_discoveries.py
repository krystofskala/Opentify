"""Objevy: nová skladba chytla = do 30 dní další 2 dny poslechu nebo
uložení; zdroj podle prvního poslechu; verze téže písně = jeden objev;
hromadný import Oblíbených se jako uložení nepočítá."""
import uuid
from datetime import datetime, timedelta

from sqlmodel import Session

from app.db import engine
from app.home import discoveries as d
from app.models import Artist, Listen, Playlist, PlaylistItem, PlaylistKind, Recording

NOW = datetime(2026, 10, 5, 12, 0)


def _rec(s, artist, title):
    r = Recording(title=title, artist_id=artist.id)
    s.add(r)
    s.commit()
    return r


def _listen(s, user, rec, at, ctx=None, src=None):
    s.add(Listen(user_id=user, recording_id=rec.id, played_at=at, duration_played_ms=200_000, context=ctx, source=src))


def test_report_counts_caught_missed_pending_and_sources():
    run = uuid.uuid4().hex[:8]
    user = "disc-" + run
    with Session(engine) as s:
        artist = Artist(name="Objev " + run)
        s.add(artist)
        s.commit()
        caught = _rec(s, artist, "Chytla")
        remaster = _rec(s, artist, "Chytla (Remastered 2011)")
        missed = _rec(s, artist, "Nechytla")
        pending = _rec(s, artist, "Čerstvá")
        saved = _rec(s, artist, "Uložená")
        old = _rec(s, artist, "Stará známá")
        t0 = NOW - timedelta(days=60)
        _listen(s, user, caught, t0, ctx="/search", src="Výsledky hledání")
        _listen(s, user, remaster, t0 + timedelta(days=3))  # jiná verze = táž píseň
        _listen(s, user, caught, t0 + timedelta(days=10))
        _listen(s, user, missed, t0, src="applemusic-history")
        _listen(s, user, missed, t0 + timedelta(days=40))  # po 30 dnech se nepočítá
        _listen(s, user, pending, NOW - timedelta(days=5), src="Pusť teď")
        _listen(s, user, saved, t0, ctx="/releases/x")
        _listen(s, user, old, NOW - timedelta(days=400))
        _listen(s, user, old, t0)
        liked = Playlist(owner_user_id=user, title="Oblíbené", kind=PlaylistKind.USER, source="liked-songs")
        s.add(liked)
        s.commit()
        s.add(PlaylistItem(playlist_id=liked.id, recording_id=saved.id, added_at=t0 + timedelta(days=2)))
        bulk = NOW - timedelta(days=50)  # hromadný import: 25 skladeb ve stejné minutě
        for i in range(25):
            s.add(PlaylistItem(playlist_id=liked.id, recording_id=missed.id if i == 0 else old.id, added_at=bulk))
        s.commit()

    r = d.report(user, days=180, now=NOW)
    by = {x["source"]: x for x in r["sources"]}
    assert by["Hledání"] == {"source": "Hledání", "new": 1, "caught": 1, "pending": 0}
    assert by["Alba"]["caught"] == 1  # uložená do Oblíbených
    assert by["Apple Music (import)"]["caught"] == 0  # jen hromadný import
    assert by["Pusť teď"]["pending"] == 1
    assert r["total"] == {"new": 4, "caught": 2, "pending": 1}  # stará známá není objev


def test_category():
    radio = Playlist(owner_user_id="x", title="r", kind=PlaylistKind.RADIO, source="radio:track:1")
    daily = Playlist(owner_user_id="x", title="d", kind=PlaylistKind.PERSONAL_MIX, source="personal:daily-mix:3")
    assert d.category("/playlists/1", "Rádio · X", radio) == "Rádio"
    assert d.category("/playlists/2", "Denní mix 3", daily) == "Denní mixy"
    assert d.category("/", "Rádio · Y", None) == "Rádio"
    assert d.category(None, "spotify-history", None) == "Spotify (import)"
    assert d.category("/shazam", None, None) == "Shazam"
