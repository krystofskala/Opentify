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


def test_same_part_titles_become_numbered(eng, tmp_path, monkeypatch):
    for rel in ["01_Saturnin.mp3", "02_Saturnin.mp3"]:
        (tmp_path / rel).write_bytes(b"neni zvuk")
    monkeypatch.setattr(importer, "_tag", lambda audio, *keys: "Saturnin" if "title" in keys else None)
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref=HASH_A, release_title="x", title="x", requested_by_user_id="me"))
        s.commit()
    importer.import_book("b1", tmp_path)
    with Session(eng) as s:
        files = s.exec(select(SpokenFile).order_by(SpokenFile.position)).all()
        assert [f.title for f in files] == ["Část 1", "Část 2"]


def test_catalog_title_survives_import(eng, tmp_path, monkeypatch):
    (tmp_path / "01.mp3").write_bytes(b"neni zvuk")
    monkeypatch.setattr(importer, "_tag", lambda audio, *keys: "Album z tagu" if "album" in keys else None)
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref=HASH_A, release_title="x", title="Saturnin",
                         metadata_source=importer.CATALOG, requested_by_user_id="me"))
        s.add(SpokenBook(id="b2", source_ref=HASH_B, release_title="y", title="y", requested_by_user_id="me"))
        s.commit()
    importer.import_book("b1", tmp_path)
    importer.import_book("b2", tmp_path)
    with Session(eng) as s:
        assert s.get(SpokenBook, "b1").title == "Saturnin"
        assert s.get(SpokenBook, "b2").title == "Album z tagu"


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


def _bencode(v) -> bytes:
    if isinstance(v, int):
        return b"i%de" % v
    if isinstance(v, str):
        v = v.encode()
    if isinstance(v, bytes):
        return b"%d:%s" % (len(v), v)
    if isinstance(v, list):
        return b"l" + b"".join(_bencode(x) for x in v) + b"e"
    return b"d" + b"".join(_bencode(k) + _bencode(v[k]) for k in sorted(v)) + b"e"


def test_torrent_files_in_client_order():
    from app.spoken.sktorrent import torrent_files

    torrent = _bencode({"announce": "x", "info": {"name": "Zaklinac", "files": [
        {"length": 10, "path": ["01 Posledni prani", "01.mp3"]},
        {"length": 20, "path": ["02 Mec osudu", "01.mp3"]},
        {"length": 5, "path": ["obal.jpg"]},
    ]}})
    assert torrent_files(torrent) == [
        {"index": 0, "path": "01 Posledni prani/01.mp3", "size": 10},
        {"index": 1, "path": "02 Mec osudu/01.mp3", "size": 20},
        {"index": 2, "path": "obal.jpg", "size": 5},
    ]
    single = _bencode({"info": {"name": "kniha.m4b", "length": 99}})
    assert torrent_files(single) == [{"index": 0, "path": "kniha.m4b", "size": 99}]


def test_import_only_selected_files(eng, tmp_path):
    for rel in ["Kniha1/01.mp3", "Kniha1/02.mp3", "Kniha2/01.mp3"]:
        p = tmp_path / rel
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(b"x")
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref="h:1", release_title="x", title="x", requested_by_user_id="me"))
        s.commit()
    only = [tmp_path / "Kniha1/02.mp3", tmp_path / "Kniha1/01.mp3"]
    assert importer.import_book("b1", tmp_path, only) == 2
    with Session(eng) as s:
        assert s.get(SpokenBook, "b1").storage_dir == str(tmp_path / "Kniha1")


def test_two_books_from_one_collection_are_separate(eng):
    with Session(eng) as s:
        a = asyncio.run(routes.acquire(routes.AcquireIn(infohash=HASH_A, title="Zaklinac komplet", files=[3, 1], folder="01 Posledni prani"), session=s, current=("me", "d")))
        b = asyncio.run(routes.acquire(routes.AcquireIn(infohash=HASH_A, title="Zaklinac komplet", files=[5], folder="02 Mec osudu"), session=s, current=("me", "d")))
        same = asyncio.run(routes.acquire(routes.AcquireIn(infohash=HASH_A, title="Zaklinac komplet", files=[1, 3]), session=s, current=("dad", "d")))
        assert a["id"] != b["id"] and same["id"] == a["id"]
        assert a["title"] == "01 Posledni prani"
        book = s.get(SpokenBook, a["id"])
        assert book.source_files == {"infohash": HASH_A, "indices": [1, 3]}


def test_progressive_import_keeps_file_ids(eng, tmp_path):
    (tmp_path / "02.mp3").write_bytes(b"x")
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref="h", release_title="x", title="x", requested_by_user_id="me"))
        s.commit()
    importer.import_book("b1", tmp_path, [tmp_path / "02.mp3"])
    with Session(eng) as s:
        first_id = s.exec(select(SpokenFile)).one().id
    (tmp_path / "01.mp3").write_bytes(b"x")
    importer.import_book("b1", tmp_path, [tmp_path / "01.mp3", tmp_path / "02.mp3"])
    with Session(eng) as s:
        files = s.exec(select(SpokenFile).order_by(SpokenFile.position)).all()
        assert [Path(f.path).name for f in files] == ["01.mp3", "02.mp3"]
        assert files[1].id == first_id  # pozice v knize (file_id) přežije


def test_first_chapter_playable_before_the_rest(eng, tmp_path, monkeypatch):
    import app.spoken.acquire as acquire

    monkeypatch.setattr(acquire, "engine", eng)

    async def no_event(*_a, **_k):
        return None

    monkeypatch.setattr(acquire, "publish_event", no_event)
    (tmp_path / "Kniha").mkdir()
    (tmp_path / "Kniha" / "01.mp3").write_bytes(b"x")
    state = {"p2": 0.3}

    async def fake_files(_h):
        return [
            {"index": 0, "name": "Kniha/01.mp3", "size": 100, "progress": 1.0},
            {"index": 1, "name": "Kniha/02.mp3", "size": 100, "progress": state["p2"]},
            {"index": 2, "name": "Kniha/obal.jpg", "size": 5, "progress": 0.0},
        ]

    monkeypatch.setattr(acquire.qbit, "files", fake_files)
    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref=HASH_A, release_title="x", title="x", status="downloading",
                         requested_by_user_id="me"))
        s.commit()
    t = {"save_path": str(tmp_path), "content_path": str(tmp_path / "Kniha"), "state": "downloading"}
    with Session(eng) as s:
        book = s.get(SpokenBook, "b1")
        s.expunge(book)
    asyncio.run(acquire._follow_torrent(book, t))
    with Session(eng) as s:
        assert s.get(SpokenBook, "b1").status == "downloading"
        assert len(s.exec(select(SpokenFile)).all()) == 1  # první kapitola už hraje
    (tmp_path / "Kniha" / "02.mp3").write_bytes(b"x")
    state["p2"] = 1.0
    asyncio.run(acquire._follow_torrent(book, t))
    with Session(eng) as s:
        assert s.get(SpokenBook, "b1").status == "ready"
        assert len(s.exec(select(SpokenFile)).all()) == 2


def test_failed_book_can_be_retried_or_removed_ready_cannot(eng):
    with Session(eng) as s:
        s.add(SpokenBook(id="bad", source_ref=HASH_A, release_title="x", title="x", status="failed", error="e", requested_by_user_id="me"))
        s.add(SpokenBook(id="ok", source_ref=HASH_B, release_title="y", title="y", status="ready", requested_by_user_id="me"))
        s.add(SpokenFile(id="f1", book_id="bad", position=0, path="/data/spoken/x.mp3"))
        s.commit()
        assert routes.retry("bad", session=s, current=("me", "d"))["status"] == "pending"
        with pytest.raises(HTTPException):
            routes.remove_failed("bad", session=s, current=("me", "d"))  # už se zase stahuje
        s.get(SpokenBook, "bad").status = "failed"
        s.commit()
        routes.remove_failed("bad", session=s, current=("me", "d"))
        assert s.get(SpokenBook, "bad") is None and s.get(SpokenFile, "f1") is None
        with pytest.raises(HTTPException):
            routes.remove_failed("ok", session=s, current=("me", "d"))
        with pytest.raises(HTTPException):
            routes.retry("ok", session=s, current=("me", "d"))


def test_failed_book_is_only_for_requester(eng, monkeypatch):
    monkeypatch.setattr(routes.download_limits, "is_admin", lambda uid: uid == "admin")
    with Session(eng) as s:
        s.add(SpokenBook(id="bad", source_ref=HASH_A, release_title="x", title="x", status="failed", error="e", requested_by_user_id="me"))
        s.add(SpokenBook(id="ok", source_ref=HASH_B, release_title="y", title="y", status="ready", requested_by_user_id="me"))
        s.commit()
        ids = lambda uid: {b["id"] for b in routes.books(session=s, current=(uid, "d"))["books"]}
        assert ids("me") == {"bad", "ok"}
        assert ids("admin") == {"bad", "ok"}
        assert ids("friend") == {"ok"}  # hotové knihy jsou sdílené, cizí chyba ne
        with pytest.raises(HTTPException):
            routes.remove_failed("bad", session=s, current=("friend", "d"))
        with pytest.raises(HTTPException):
            routes.retry("bad", session=s, current=("friend", "d"))
        assert routes.retry("bad", session=s, current=("admin", "d"))["status"] == "pending"


def test_title_tag_in_wrong_encoding_is_fixed_only_when_file_name_agrees():
    assert importer.fix_title_encoding("02 Zaklínaè", "02 Zaklínač") == "02 Zaklínač"
    assert importer.fix_title_encoding("10 Konec svìta", "10 Konec světa") == "10 Konec světa"
    assert importer.fix_title_encoding("06 Men\x9aí zlo", "06 Menší zlo") == "06 Menší zlo"
    # Skutečné "è" a soubor jinak pojmenovaný -> beze změny.
    assert importer.fix_title_encoding("Pièce montée", "01 Piece montee") == "Pièce montée"
    assert importer.fix_title_encoding("Kapitola 1", "track01") == "Kapitola 1"


def test_person_page_books_on_server_and_releases_to_download(eng, monkeypatch):
    """Stránka autora: knihy na serveru (bez diakritiky, obě pořadí jména),
    vydání ke stažení bez těch, co už jsou výš; cizí nepovedené stažení ne."""
    import asyncio

    from app.spoken import sktorrent

    with Session(eng) as s:
        s.add(SpokenBook(id="b1", source_ref=HASH_A, release_title="x", title="Saturnin", author="Jirotka, Zdeněk",
                         status="ready", requested_by_user_id="dad"))
        s.add(SpokenBook(id="b2", source_ref=HASH_B, release_title="y", title="Muž se psem", author="Zdenek Jirotka",
                         narrator="Oldřich Vízner", status="failed", requested_by_user_id="dad"))
        s.add(SpokenBook(id="b3", source_ref="h3", release_title="z", title="Jiná", author="Karel Čapek",
                         status="ready", requested_by_user_id="me"))
        s.commit()

        async def fake_search(q):
            assert q == "Zdeněk Jirotka"
            return [
                sktorrent.Release(infohash=HASH_A, title="Saturnin - Zdeněk Jirotka", size_bytes=1, seeders=3, leechers=0, cover_url=None, added=None),
                sktorrent.Release(infohash="new1", title="Profesor Kujal - Zdeněk Jirotka", size_bytes=1, seeders=5, leechers=0, cover_url=None, added=None),
            ]

        monkeypatch.setattr(sktorrent, "search", fake_search)
        out = asyncio.run(routes.person("Zdeněk Jirotka", session=s, current=("me", "d")))
        assert [b["id"] for b in out["books"]] == ["b1"]  # b2 je cizí nepovedené, b3 jiný autor
        assert out["books"][0]["mine"] is False
        assert [r["infohash"] for r in out["releases"]] == ["new1"]
        narr = asyncio.run(routes.person("Oldrich Vizner", role="narrator", session=s, current=("dad", "d")))
        assert [b["id"] for b in narr["books"]] == ["b2"] and narr["role"] == "narrator"
