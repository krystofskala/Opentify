"""Doporučení knih: od autorů, které posloucháš, pak populární; bez stažených."""
from __future__ import annotations

import asyncio

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.spoken.recommend as recommend
from app.models import SpokenBook, SpokenProgress
from app.spoken.sktorrent import Release


def _rel(h: str, title: str, seeds: int) -> Release:
    return Release(infohash=h * 40, title=title, size_bytes=1, seeders=seeds, leechers=0, cover_url=None, added=None)


def test_books_by_author_then_popular_without_owned(monkeypatch):
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    monkeypatch.setattr(recommend, "engine", eng)
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref="a" * 40, release_title="x", title="Saturnin", author="Zdeněk Jirotka",
                         requested_by_user_id="me"))
        s.add(SpokenProgress(user_id="me", book_id="b1", file_id="f"))
        s.commit()

    async def search(q):
        assert q == "Zdeněk Jirotka"
        return [_rel("a", "Saturnin (už mám)", 9), _rel("b", "Muž s ocelovou vůlí", 5), _rel("c", "Bez zdrojů", 0)]

    async def latest():
        return [_rel("b", "Muž s ocelovou vůlí", 5), _rel("d", "Sága o impériu", 80)]

    monkeypatch.setattr(recommend.sktorrent, "search", search)
    monkeypatch.setattr(recommend.sktorrent, "latest", latest)
    out = asyncio.run(recommend.books_for("me"))
    assert [(b["title"], b["reason"]) for b in out] == [
        ("Muž s ocelovou vůlí", "Od autora Zdeněk Jirotka"),
        ("Sága o impériu", "Populární teď"),
    ]


def test_hearted_author_first_and_no_other_edition_of_my_book(monkeypatch):
    from app.models import SpokenFavorite

    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    monkeypatch.setattr(recommend, "engine", eng)
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref="a" * 40, release_title="x", title="Saturnin", author="Zdeněk Jirotka",
                         requested_by_user_id="me"))
        s.add(SpokenProgress(user_id="me", book_id="b1", file_id="f"))
        s.add(SpokenFavorite(user_id="me", kind="person", ref="author:karel capek", name="Karel Čapek"))
        s.commit()
    searched = []

    async def search(q):
        searched.append(q)
        return [_rel("e", "Saturnin - Zdeněk Jirotka (čte Oldřich Vízner)", 30), _rel("f", "Krakatit - Karel Čapek", 9)]

    async def latest():
        return []

    monkeypatch.setattr(recommend.sktorrent, "search", search)
    monkeypatch.setattr(recommend.sktorrent, "latest", latest)
    out = asyncio.run(recommend.books_for("me"))
    assert searched[0] == "Karel Čapek"  # srdíčko napřed
    assert [b["title"] for b in out] == ["Krakatit - Karel Čapek"]  # jiné vydání Saturnina ne
