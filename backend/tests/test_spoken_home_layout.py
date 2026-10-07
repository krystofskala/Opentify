"""Domů mluveného slova: pořadí a skrytí sekcí podle profilu."""
from __future__ import annotations

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.spoken.home_layout as hl
from app.models import HomeSnapshot


@pytest.fixture(autouse=True)
def eng(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(hl, "engine", e)
    return e


def ids(entries):
    return [e["id"] for e in entries]


def test_default_everything_visible_in_default_order():
    out = hl.entries("u1")
    assert ids(out) == [sid for sid, _ in hl.SECTIONS]
    assert all(e["visible"] for e in out)


def test_per_profile_order_and_hidden(eng):
    rest = [sid for sid, _ in hl.SECTIONS if sid not in ("others_books", "continue")]
    hl.save("u1", ["others_books", "continue", "bogus", *rest], ["rec_podcasts"])
    out = hl.entries("u1")
    assert ids(out)[:2] == ["others_books", "continue"]
    assert {e["id"]: e["visible"] for e in out}["rec_podcasts"] is False
    assert "bogus" not in ids(out)
    # Jiný profil má výchozí.
    assert ids(hl.entries("u2")) == [sid for sid, _ in hl.SECTIONS]


def test_new_section_lands_after_its_predecessor(eng):
    with Session(eng) as s:
        s.add(HomeSnapshot(key=hl.layout_key("u1"), payload={"order": ["my_books", "continue"], "visible": {}}))
        s.commit()
    order = ids(hl.entries("u1"))
    assert order.index("shows") == order.index("my_books") + 1
    assert order.index("new_episodes") == order.index("continue") + 1


def test_reset(eng):
    hl.save("u1", ["downloading"], ["continue"])
    out = hl.save("u1", [], [])
    assert ids(out) == [sid for sid, _ in hl.SECTIONS] and all(e["visible"] for e in out)
