"""Rádio: stejná píseň jen jednou ani u zdvojeného interpreta."""

import uuid

from sqlmodel import Session

from app.db import engine
from app.home.radio_station import _unique_songs
from app.models import Artist, Recording


def _rec(s: Session, artist: str, title: str) -> str:
    a = Artist(name=artist)
    s.add(a)
    s.flush()
    r = Recording(title=title, artist_id=a.id)
    s.add(r)
    s.flush()
    return r.id


def test_same_song_from_duplicated_artist_once() -> None:
    tag = uuid.uuid4().hex[:6]
    with Session(engine) as s:
        a = _rec(s, f"Kane {tag}", "Damn Those Eyes")
        b = _rec(s, f"KANE {tag}", "Damn Those Eyes")
        c = _rec(s, f"Kane {tag}", "Rain Down On Me")
        s.commit()
    assert _unique_songs([a, b, c]) == [a, c]
