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


def test_known_capped_new_kept() -> None:
    from app.home.radio_station import _cap_known

    assert _cap_known(["k1", "n1", "k2", "k3", "n2"], {"k1", "k2", "k3"}, 2) == ["k1", "n1", "k2", "n2"]
    # Známé napřed se rozloží mezi nové.
    assert _cap_known(["k1", "k2", "n1", "n2", "n3", "n4"], {"k1", "k2"}, 2) == ["k1", "n1", "n2", "k2", "n3", "n4"]


def test_seed_song_not_repeated_under_other_artist() -> None:
    from app.home.radio_station import _unique_after

    tag = uuid.uuid4().hex[:6]
    with Session(engine) as s:
        seed = _rec(s, f"Kane {tag}", "Damn Those Eyes")
        twin = _rec(s, f"KANE {tag}", "Damn Those Eyes")
        other = _rec(s, f"KANE {tag}", "Rain Down On Me")
        s.commit()
    assert _unique_after([seed], [twin, other]) == [other]


def test_known_limit_counts_seed_and_short_station() -> None:
    from app.home.radio_station import _drop_known_over, _known_limit

    heard = {"seed", "k1", "k2", "k3"}
    # Známé semínko se počítá do třetiny; krátká stanice: půl známé na novou.
    assert _known_limit(["k1", "k2", "k3", "n1", "n2"], ["seed"], heard) == 0
    assert _known_limit(["k1"] + [f"n{i}" for i in range(40)], ["seed"], heard) == 15
    assert _known_limit(["k1", "k2"], [], heard) == 0
    assert _drop_known_over(["k1", "n1", "k2", "k3"], heard, 1) == ["k1", "n1"]
