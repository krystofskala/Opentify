"""Blend: vkus z vrstev, filtry obou, doplnění tenké strany, bez kopií."""

import asyncio
import uuid
from datetime import timedelta

from sqlmodel import Session, select

from app import blends
from app.db import engine
from app.home import taste_cache
from app.models import Artist, ArtistFeedback, Blend, Listen, Playlist, Recording
from app.utils import utcnow


def _recs(prefix: str, n: int) -> list[str]:
    with Session(engine) as s:
        out = []
        for i in range(n):
            a = Artist(name=f"{prefix} {i} {uuid.uuid4().hex[:6]}")
            s.add(a)
            s.flush()
            r = Recording(title=f"{prefix} song {i}", artist_id=a.id)
            s.add(r)
            s.flush()
            out.append(r.id)
        s.commit()
        return out


def _listen(user: str, ids: list[str]) -> None:
    t = (utcnow() - timedelta(days=2)).replace(tzinfo=None)
    with Session(engine) as s:
        for rid in ids:
            s.add(Listen(user_id=user, recording_id=rid, played_at=t, source="Výsledky hledání"))
        s.commit()


def test_blend_balances_thin_partner_and_respects_both_filters(monkeypatch) -> None:
    rich, thin = "bl-rich-" + uuid.uuid4().hex[:6], "bl-thin-" + uuid.uuid4().hex[:6]
    rich_tracks = _recs("Rich", 40)
    thin_tracks = _recs("Thin", 1)
    similar = _recs("Like thin", 20)
    _listen(rich, rich_tracks)
    _listen(thin, thin_tracks)
    with Session(engine) as s:
        muted_artist = s.get(Recording, rich_tracks[0]).artist_id
        s.add(ArtistFeedback(user_id=thin, artist_id=muted_artist, delta=-10))  # partner nechce
        b = Blend(user_a=rich, user_b=thin, created_by=rich, status="active")
        s.add(b)
        s.commit()
        blend_id = b.id
    taste_cache.invalidate()

    async def fake_similar(seeds, users, exclude, rng, want):
        return [r for r in similar if r not in exclude][:want]

    monkeypatch.setattr(blends, "_similar_for", fake_similar)
    asyncio.run(blends.build_async(blend_id))
    with Session(engine) as s:
        pls = {p.source.rsplit(":", 1)[-1]: p for p in s.exec(select(Playlist).where(Playlist.owner_user_id == rich, Playlist.source.like(f"blend:{blend_id}:%"))).all()}
        assert "blend" in pls
        from app.models import PlaylistItem

        items = [i.recording_id for i in s.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == pls["blend"].id).order_by(PlaylistItem.position)).all()]
    assert rich_tracks[0] not in items  # "míň takových" partnera platí
    thin_side = [r for r in items if r in set(thin_tracks) | set(similar)]
    assert len(thin_side) >= 10  # tenká strana doplněná podobnými, ne pár skladeb mezi cizími
    if "new" in pls:
        with Session(engine) as s:
            from app.models import PlaylistItem

            new = {i.recording_id for i in s.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == pls["new"].id)).all()}
        assert not new & set(items)  # Nové objevy nekopírují Blend
