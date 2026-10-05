""""Proč tohle?" (plán P2) -- důvod jen na vyžádání (menu skladby), nikdy
u každé skladby. Jemně a bez sledovacích čísel: "Patřila mezi tvé oblíbené
v roce 2017", ne "47× v létě 2017"."""

from __future__ import annotations

from datetime import timedelta

from sqlmodel import Session

from app.catalog.availability import recording_artist_name
from app.db import engine
from app.home import activation as av
from app.library.spotify_import import get_or_create_liked_songs_playlist
from app.models import PlaylistItem, Recording
from app.utils import utcnow


def reason(user_id: str, recording_id: str) -> str:
    from sqlmodel import select

    act = av.compute(user_id)
    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
        if rec is None:
            return "Tuhle skladbu neznám."
        artist_name = recording_artist_name(session, rec) or "tohoto interpreta"
        liked_pl = get_or_create_liked_songs_playlist(session, user_id)
        liked = session.exec(
            select(PlaylistItem.id).where(PlaylistItem.playlist_id == liked_pl.id, PlaylistItem.recording_id == recording_id)
        ).first() is not None
    now = utcnow()
    if liked:
        return "Máš ji v oblíbených."
    if recording_id in act.total:
        last = act.last.get(recording_id)
        if last and now - last <= timedelta(days=30):
            return "Posloucháš ji poslední dobou."
        peak = act.peak.get(recording_id, 0)
        peak_at = act.peak_at.get(recording_id)
        if peak >= av.PEAK_MIN and peak_at:
            return f"Patřila mezi tvé oblíbené v roce {peak_at.year}."
        return "Už jsi ji někdy slyšel/a."
    artist_known = rec.artist_id and any(a == rec.artist_id for a in act.artist_of.values())
    if artist_known:
        return f"Od interpreta, kterého posloucháš ({artist_name})."
    return "Nová pro tebe – podobná hudbě, kterou posloucháš."
