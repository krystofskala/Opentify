"""Mluvené slovo: SkTorrent výpis, import souborů, "Stáhnout" a pozice."""
from __future__ import annotations

import asyncio

from pathlib import Path

import pytest
from fastapi import HTTPException
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

import app.spoken.importer as importer
import app.routes.spoken as routes
from app.models import SpokenBook, SpokenFile, SpokenProgress
from app.spoken.sktorrent import parse_results

HASH_A = "2dce9ad02753466981d1c8ae819a95618c5e652d"
HASH_B = "72a5c49b90f75ce1fac16180ce6359f0476f6714"


def _cell(cat: str, h: str, title: str, size: str, seed: int) -> str:
    return (
        f"<TD><a href=torrents_v2.php?category={cat} title='Stiahni si X'><b>X</b></a><br>"
        f'<A HREF="details.php?name=Saturnin-31&id={h}" title="Stiahni si Mluvené slovo {title}">'
        f"<img></A><br>Velkost {size} | Pridany 21/01/2025<br> Odosielaju : {seed}<br> Stahuju : 1 </div></td>"
    )


def test_parse_results_keeps_only_spoken_word_and_reads_numbers():
    page = _cell("1", HASH_B, "Saturnin (1994) film", "2.9 GB", 6) + _cell(
        "24", HASH_A, "Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner", "500.4 MB", 8
    )
    [r] = parse_results(page)
    assert r.infohash == HASH_A
    assert r.title == "Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner"
    assert r.size_bytes == int(500.4 * 1024**2)
    assert (r.seeders, r.leechers) == (8, 1)
    assert r.cover_url == f"spoken/cover/{HASH_A}"  # přes náš server, ne přímo


def test_sktorrent_never_goes_direct(monkeypatch):
    from app.spoken import sktorrent

    monkeypatch.setenv("SKTORRENT_PROXY", "")
    assert sktorrent._proxy() == "http://gluetun:8888"
    monkeypatch.delenv("SKTORRENT_PROXY")
    assert sktorrent._proxy() == "http://gluetun:8888"


def test_guess_narrator_from_release_title():
    g = importer.guess_from_release("Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner")
    assert g["narrator"] == "Oldřich Vízner"
    assert g["title"] == "Saturnin - Zdeněk Jirotka"
    g = importer.guess_from_release("Jirotka Zdeněk - Saturnin (2003)(čte Svatopluk Beneš)")
    assert g["narrator"] == "Svatopluk Beneš"
    assert g["title"] == "Jirotka Zdeněk - Saturnin"
    assert importer.guess_from_release("Velka audiokniha pohadek (2011 CZ)")["narrator"] is None


@pytest.fixture
def eng(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(importer, "engine", e)
    return e


def test_import_orders_cd_folders_and_numbers_naturally(eng, tmp_path):
    for rel in ["CD2/01 - konec.mp3", "CD1/10 - deset.mp3", "CD1/2 - dva.mp3", "obal.jpg"]:
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"neni zvuk")
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref=HASH_A, release_title="x", title="x", requested_by_user_id="me"))
        s.commit()
    assert importer.import_book("b1", tmp_path) == 3
    with Session(eng) as s:
        files = s.exec(select(SpokenFile).order_by(SpokenFile.position)).all()
        assert [Path(f.path).name for f in files] == ["2 - dva.mp3", "10 - deset.mp3", "01 - konec.mp3"]
        assert s.get(SpokenBook, "b1").storage_dir == str(tmp_path)


def test_one_format_per_book(tmp_path):
    for rel in ["a/kniha.mp3", "a/kniha_64kb.mp3", "a/kniha.ogg", "a/kniha.m4b"]:
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    assert [p.name for p in importer.audio_files(tmp_path)] == ["kniha.m4b"]
    (tmp_path / "a/kniha.m4b").unlink()
    (tmp_path / "a/kniha2.mp3").write_bytes(b"x")
    assert sorted(p.name for p in importer.audio_files(tmp_path)) == ["kniha.mp3", "kniha2.mp3"]


def test_acquire_twice_is_one_book_and_failed_retries(eng):
    body = routes.AcquireIn(infohash=HASH_A.upper(), title="Saturnin (2010) čte Oldřich Vízner", coverUrl="https://evil.example/x.jpg")
    with Session(eng) as s:
        first = asyncio.run(routes.acquire(body, session=s, current=("me", "d")))
        second = asyncio.run(routes.acquire(body, session=s, current=("dad", "d")))
        assert first["id"] == second["id"]
        assert first["coverUrl"] == f"spoken/cover/{HASH_A}"  # nikdy adresa od klienta
        assert first["narrator"] == "Oldřich Vízner"
        book = s.get(SpokenBook, first["id"])
        book.status, book.error = "failed", "torrent: error"
        s.add(book)
        s.commit()
        again = asyncio.run(routes.acquire(body, session=s, current=("me", "d")))
        assert (again["status"], again["error"]) == ("pending", None)
        with pytest.raises(HTTPException):
            asyncio.run(routes.acquire(routes.AcquireIn(infohash="nope", title="x"), session=s, current=("me", "d")))


def test_progress_is_per_profile_and_file_must_belong_to_book(eng):
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref=HASH_A, release_title="x", title="x", requested_by_user_id="me"))
        s.add(SpokenBook(id="b2", source_ref=HASH_B, release_title="y", title="y", requested_by_user_id="me"))
        s.add(SpokenFile(id="f1", book_id="b1", position=0, path="/data/spoken/a.mp3"))
        s.add(SpokenFile(id="f2", book_id="b2", position=0, path="/data/spoken/b.mp3"))
        s.commit()
        routes.save_progress("b1", routes.ProgressIn(fileId="f1", positionMs=61000), session=s, current=("me", "d"))
        routes.save_progress("b1", routes.ProgressIn(fileId="f1", positionMs=5000), session=s, current=("dad", "d"))
        with pytest.raises(HTTPException):
            routes.save_progress("b1", routes.ProgressIn(fileId="f2", positionMs=1), session=s, current=("me", "d"))
        mine = routes.book_detail("b1", session=s, current=("me", "d"))["progress"]
        assert mine["positionMs"] == 61000
        assert len(s.exec(select(SpokenProgress)).all()) == 2


def test_stream_only_from_spoken_folder(eng, tmp_path, monkeypatch):
    monkeypatch.setattr(routes, "SPOKEN_ROOT", tmp_path)
    inside = tmp_path / "a.mp3"
    inside.write_bytes(b"x")
    with Session(eng) as s:
        s.add(SpokenFile(id="ok", book_id="b", position=0, path=str(inside)))
        s.add(SpokenFile(id="bad", book_id="b", position=1, path="/etc/passwd"))
        s.commit()
        assert routes.stream_file("ok", session=s).path == inside
        with pytest.raises(HTTPException):
            routes.stream_file("bad", session=s)
