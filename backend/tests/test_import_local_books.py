"""Vlastní audioknihy ze složek (app/tools/import_local_books.py)."""
from pathlib import Path

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

import app.spoken.importer as importer
import app.tools.import_local_books as tool
from app.models import SpokenBook, SpokenFile


@pytest.fixture
def eng(monkeypatch, tmp_path):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(importer, "engine", e)
    monkeypatch.setattr(tool, "engine", e)
    monkeypatch.setattr(tool, "SPOKEN_ROOT", tmp_path / "spoken")
    (tmp_path / "spoken").mkdir()
    return e


def test_folder_becomes_ready_book_once_and_mac_junk_is_skipped(eng, tmp_path):
    src = tmp_path / "_import" / "Brambora byla pomeranč mého dětství"
    src.mkdir(parents=True)
    for n in ("01.mp3", "02.mp3", "._02.mp3"):
        (src / n).write_bytes(b"x" * 10)
    [folder] = tool.books_in(tmp_path / "_import")
    book_id, count = tool.import_folder(folder)
    assert count == 2  # bez ._02.mp3
    with Session(eng) as s:
        book = s.get(SpokenBook, book_id)
        assert book.status == "ready" and book.source == "local" and book.title == "Brambora byla pomeranč mého dětství"
        assert len(s.exec(select(SpokenFile)).all()) == 2
    # Znovu stejná složka (třeba nová kopie) -> nepřidá se podruhé.
    again = tmp_path / "_import2" / "Brambora byla pomeranč mého dětství"
    again.mkdir(parents=True)
    for n in ("01.mp3", "02.mp3"):
        (again / n).write_bytes(b"x" * 10)
    assert tool.import_folder(again) is None
