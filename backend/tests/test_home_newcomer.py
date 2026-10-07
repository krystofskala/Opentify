"""Domů nového profilu: pořadí, Žánry k prozkoumání, karty na konci,
„Teď ne“, a start Pusť teď „z čeho“."""
from __future__ import annotations

import asyncio
import uuid

from sqlmodel import Session

from app.db import engine
from app.home import play_now as pn
from app.home import service as svc
from app.models import Artist, Playlist, PlaylistKind, Recording

_RUN = uuid.uuid4().hex[:8]


def _sections(*ids):
    return [{"id": i, "title": i, "type": "playlist_cards", "items": [1]} for i in ids]


def test_newcomer_order_genres_on_and_setup_last():
    user = "nc-" + _RUN
    secs = _sections("continue", "charts", "new_releases", "genres", "quick_picks", "czech", "newcomer_setup", "album_picks")
    with Session(engine) as s:
        out = [x["id"] for x in svc.apply_layout(s, user, secs)]
    assert out[:3] == ["continue", "quick_picks", "album_picks"]
    assert out.index("genres") < out.index("new_releases") < out.index("charts")
    assert out[-1] == "newcomer_setup"


def test_regular_profile_keeps_genres_off():
    user = "nc-reg-" + _RUN
    with Session(engine) as s:
        s.add(Playlist(owner_user_id=user, title="Denní mix 1", kind=PlaylistKind.PERSONAL_MIX, source="personal:daily-mix:1"))
        s.commit()
        out = [x["id"] for x in svc.apply_layout(s, user, _sections("continue", "quick_picks", "genres", "charts"))]
    assert "genres" not in out


def test_dismiss_and_undo(monkeypatch):
    from app.routes import home as routes

    async def nothing(_u):
        return None

    monkeypatch.setattr(svc, "invalidate_home_cache_for", nothing)
    user = "nc-dis-" + _RUN
    out = asyncio.run(routes.newcomer_dismiss(routes.NewcomerDismissIn(card="import"), current=(user, "d")))
    assert out["dismissed"] == ["import"]
    with Session(engine) as s:
        assert "import" in svc.get_layout(s, user)["dismissed"]
    out = asyncio.run(routes.newcomer_dismiss(routes.NewcomerDismissIn(card="import", undo=True), current=(user, "d")))
    assert out["dismissed"] == []


def test_start_from_artist_plays_their_top_then_similar(monkeypatch):
    with Session(engine) as s:
        a = Artist(name="Start " + _RUN)
        b = Artist(name="Similar " + _RUN)
        s.add_all([a, b])
        s.flush()
        top = [Recording(title=f"top {i}", artist_id=a.id) for i in range(3)]
        sim = [Recording(title=f"sim {i}", artist_id=b.id) for i in range(2)]
        s.add_all(top + sim)
        s.commit()
        aid, top_ids, sim_ids = a.id, [r.id for r in top], [r.id for r in sim]

    async def fake_top(artist_id):
        return [{"id": r} for r in top_ids]

    async def fake_similar(seeds, exclude, rng, n):
        return sim_ids + top_ids

    async def nothing(*_a, **_k):
        return None

    import app.catalog.top_tracks as tt
    from app.home import lastfm_taste as lt

    monkeypatch.setattr(tt, "artist_top_tracks", fake_top)
    monkeypatch.setattr(lt, "similar_track_ids", fake_similar)
    monkeypatch.setattr(pn, "_prefetch", nothing)
    out = asyncio.run(pn.start_from("nc-start-" + _RUN, aid, None, 10))
    assert out["recordingIds"][:2] == top_ids[:2]
    assert sim_ids[0] in out["recordingIds"] and sim_ids[1] not in out["recordingIds"]  # 1 na interpreta
    assert out["reason"].startswith("Začínám od Start")


def test_album_picks_explore_share_shrinks_with_confirmed_taste():
    from app.home.extra_sections import blend, explore_share

    assert explore_share(True, 0) == 1.0
    assert explore_share(True, 6) == 0.5
    assert explore_share(True, 40) == 0.25  # mladý profil: aspoň čtvrtina napříč žánry
    assert explore_share(False, 0) == 0.0  # zaběhlý profil: jen podle vkusu
    row = blend(list("CCCCCCCC"), list("pppppppp"), 0.25)[:8]
    assert row.count("C") == 2 and row[0] == "C"
    assert blend(["C1"], [], 0.25) == ["C1"]


def test_album_picks_display_mode_in_layout():
    from app.models import HomeSnapshot

    user = "nc-mode-" + _RUN
    entry = next(e for e in svc.layout_entries(user) if e["id"] == "album_picks")
    assert entry["mode"] == "row" and entry["visible"]  # nováček: řada, zapnutá
    with Session(engine) as s:
        s.add(HomeSnapshot(key=svc.layout_key(user), payload={"order": [], "visible": {}, "display": {"album_picks": "one"}}))
        s.commit()
    entry = next(e for e in svc.layout_entries(user) if e["id"] == "album_picks")
    assert entry["mode"] == "one"
