"""Knihy na serveru -> řada, díl a vlastní obal (komplety)."""
import asyncio
from pathlib import Path

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.models import SpokenBook
from app.spoken import describe, series, series_link

_ZAKLINAC = {"name": "Sága o zaklínači", "author": "Andrzej Sapkowski", "parts": [
    {"title": "Poslední přání", "number": 1}, {"title": "Krev elfů", "number": 3}], "loose": []}


def test_title_candidates_from_folder_names():
    assert series_link.title_candidates("kniha 1.poslední přání")[0] == "poslední přání"
    assert series_link.title_candidates("Zaklinac I - Posledni prani")[0] == "Posledni prani"
    assert series_link.title_candidates("01 - Krev elfu (2015)")[0] == "Krev elfu"
    assert series_link.title_candidates("Saturnin") == ["Saturnin"]


def _engine(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(series_link, "engine", e)
    return e


def test_link_sets_part_title_and_own_cover_for_collection(monkeypatch, tmp_path: Path):
    e = _engine(monkeypatch)
    import app.spoken.acquire as acquire

    monkeypatch.setattr(acquire, "SPOKEN_ROOT", tmp_path)

    async def fake_lookup(title, author):
        return _ZAKLINAC if "posledni" in title.lower() or "krev" in title.lower() else None

    async def fake_cover(title, author, dest):
        dest.parent.mkdir(parents=True, exist_ok=True)
        dest.write_bytes(b"x")
        return True

    monkeypatch.setattr(series, "lookup", fake_lookup)
    monkeypatch.setattr(describe, "cover_image", fake_cover)
    with Session(e) as s:
        for i, t in enumerate(["Zaklinac I - Posledni prani", "Zaklinac III - Krev elfu"]):
            s.add(SpokenBook(id=f"b{i}", source_ref=f"h:{i}", release_title="Zaklinac komplet", title=t,
                             author="Andrzej Sapkowski", status="ready", cover_url="spoken/covers/h", requested_by_user_id="me"))
        s.commit()
        book = s.get(SpokenBook, "b0")
        s.expunge(book)
    fields = asyncio.run(series_link.link(book))
    assert fields == {"series_name": "Sága o zaklínači", "series_number": 1, "title": "Poslední přání",
                      "cover_url": "spoken/books/b0/cover"}
    assert (tmp_path / "covers" / "b0.jpg").is_file()


def test_link_without_series_marks_checked(monkeypatch):
    _engine(monkeypatch)

    async def none(title, author):
        return None

    monkeypatch.setattr(series, "lookup", none)
    book = SpokenBook(id="x", source_ref="x", release_title="Saturnin", title="Saturnin", author="Zdeněk Jirotka",
                      requested_by_user_id="me")
    assert asyncio.run(series_link.link(book)) == {"series_name": ""}


def test_pick_cover_strict():
    items = [
        {"volumeInfo": {"title": "Zaklínač", "language": "cs", "authors": ["Andrzej Sapkowski"],
                        "imageLinks": {"thumbnail": "http://x/game.jpg"}}},
        {"volumeInfo": {"title": "Krev elfů", "language": "cs", "authors": ["Andrzej Sapkowski"],
                        "imageLinks": {"thumbnail": "http://x/t.jpg&edge=curl", "large": "http://x/l.jpg"}}},
    ]
    assert describe.pick_cover(items, "Krev elfů", "Andrzej Sapkowski") == "https://x/l.jpg"
    assert describe.pick_cover(items, "Věž vlaštovky", "Andrzej Sapkowski") is None


def test_book_without_author_gets_author_from_series(monkeypatch):
    _engine(monkeypatch)

    async def fake_lookup(title, author):
        assert author == ""
        return {"name": "Harry Potter", "author": "Joanne Rowlingová",
                "parts": [{"title": "Harry Potter a vězeň z Azkabanu", "number": 3}], "loose": []}

    async def no_cover(*a):
        return False

    monkeypatch.setattr(series, "lookup", fake_lookup)
    monkeypatch.setattr(describe, "cover_image", no_cover)
    book = SpokenBook(id="hp", source_ref="hp", release_title="x", title="Harry Potter a Vězeň z Azkabanu",
                      cover_url="spoken/books/hp/cover", requested_by_user_id="me")
    fields = asyncio.run(series_link.link(book))
    assert fields["author"] == "Joanne Rowlingová" and fields["series_number"] == 3


def test_junk_author_from_tags_is_replaced(monkeypatch):
    _engine(monkeypatch)
    calls = []

    async def fake_lookup(title, author):
        calls.append(author)
        if author:  # "Harry Potter" jako autor nesedí
            return None
        return {"name": "Harry Potter", "author": "Joanne Rowlingová",
                "parts": [{"title": "Harry Potter a Fénixův řád", "number": 5}], "loose": []}

    async def no_cover(*a):
        return False

    monkeypatch.setattr(series, "lookup", fake_lookup)
    monkeypatch.setattr(describe, "cover_image", no_cover)
    book = SpokenBook(id="hp5", source_ref="hp5", release_title="x", title="Harry Potter a Fénixův řád",
                      author="Harry Potter", cover_url="spoken/books/hp5/cover", requested_by_user_id="me")
    fields = asyncio.run(series_link.link(book))
    assert calls == ["Harry Potter", ""] and fields["author"] == "Joanne Rowlingová" and fields["series_number"] == 5
    assert series_link.junk_author("01", "x") and not series_link.junk_author("Pavel Zedníček", "J. K. Rowlingová: Harry Potter")
