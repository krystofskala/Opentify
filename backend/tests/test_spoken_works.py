"""Stránka knihy: všechna vydání, doporučené nahoře (fáze 2)."""
import asyncio

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.spoken.works as works
from app.models import SpokenBook
from app.spoken import catalog, sktorrent


def rec(title, author, summary=None):
    return {"id": title, "title": title, "shortTitle": title, "authors": {"primary": {author: []}, "secondary": {}},
            "formats": ["0/BOOKS/"], "publicationDates": ["2022"], "summary": [summary] if summary else []}


def rel(h, title, seeders):
    return sktorrent.Release(infohash=h, title=title, size_bytes=1, seeders=seeders, leechers=0, cover_url=None, added=None)


def test_rank_prefers_complete_unabridged_seeded():
    full = {"seeders": 5, "narrator": "Oldřich Vízner"}
    part = {"seeders": 20, "cdPart": True}
    dead = {"seeders": 0}
    scores = {k: works.rank(v, set())[0] for k, v in {"full": full, "part": part, "dead": dead}.items()}
    assert scores["full"] > scores["dead"] > scores["part"] or scores["full"] > scores["part"]
    assert works.rank(full, {"oldrich vizner"})[0] > works.rank(full, set())[0]
    assert "celé" in works.rank(full, set())[1]


@pytest.fixture
def eng(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(works, "engine", e)
    return e


def test_work_page_keeps_only_this_books_editions(eng, monkeypatch):
    records = [rec("Saturnin", "Zdeněk Jirotka, 1911-2003", "Humoristický román."), rec("Saturnin se vrací", "Miroslav Macek, 1944-")]

    async def fake_search(lookfor, limit=20):
        return records

    async def fake_sk(q):
        return [
            rel("a", "Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner", 12),
            rel("b", "Miroslav Macek - Saturnin se vraci (2017)(CZ)", 30),
            rel("c", "Zdenek Jirotka - Saturnin 2. CD (2007)(CZ)", 40),
            rel("d", "Jirotka - Saturnin (Kompletní sbírka) (CZ)", 9),
        ]

    monkeypatch.setattr(catalog, "_search", fake_search)
    monkeypatch.setattr(sktorrent, "search", fake_sk)
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref="x", release_title="Jirotka Zdeněk - Saturnin (2003)(čte Svatopluk Beneš)",
                         title="Saturnin", author="Zdeněk Jirotka", status="ready", requested_by_user_id="dad"))
        s.commit()
    page = asyncio.run(works.work_page("Saturnin", "Zdeněk Jirotka", "me"))
    assert page["work"]["title"] == "Saturnin" and page["work"]["summary"] == "Humoristický román."
    ids = [e.get("bookId") or e.get("infohash") for e in page["editions"]]
    assert set(ids) == {"b1", "a", "c"}  # Macek ani sbírka ne
    assert page["recommended"]["bookId"] == "b1"  # na serveru, pustíš hned
    assert ids[-1] == "c"  # jen část CD na konci
