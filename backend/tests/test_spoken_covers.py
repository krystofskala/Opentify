"""Obaly audioknih: záložní řetěz, Špatný obal, vlastní obal."""
import asyncio
import io
from pathlib import Path

from PIL import Image
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.spoken.acquire as acquire
from app.models import SpokenBook, SpokenFile
from app.spoken import covers


class FakeRedis:
    def __init__(self):
        self.kv, self.sets = {}, {}

    async def get(self, k):
        return self.kv.get(k)

    async def set(self, k, v, ex=None, nx=False):
        if nx and k in self.kv:
            return False
        self.kv[k] = v
        return True

    async def delete(self, k):
        self.kv.pop(k, None)

    async def sadd(self, k, v):
        self.sets.setdefault(k, set()).add(v)

    async def smembers(self, k):
        return self.sets.get(k, set())


def _jpg(color="red") -> bytes:
    buf = io.BytesIO()
    Image.new("RGB", (300, 300), color).save(buf, "JPEG")
    return buf.getvalue()


def _setup(monkeypatch, tmp_path: Path):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(covers, "engine", e)
    monkeypatch.setattr(acquire, "engine", e)
    monkeypatch.setattr(acquire, "SPOKEN_ROOT", tmp_path)

    async def no_event(*a, **k):
        return None

    monkeypatch.setattr(acquire, "publish_event", no_event)
    folder = tmp_path / "torrent" / "kniha 3"
    folder.mkdir(parents=True)
    (folder / "01.mp3").write_bytes(b"not audio")
    (folder / "cover.jpg").write_bytes(_jpg())
    with Session(e) as s:
        s.add(SpokenBook(id="b", source_ref="b", release_title="x", title="Krev elfů", author="Andrzej Sapkowski",
                         status="ready", cover_url="spoken/covers/hash", requested_by_user_id="me"))
        s.add(SpokenFile(id="f", book_id="b", position=0, path=str(folder / "01.mp3")))
        s.commit()
    return e


def test_folder_image_then_reject_falls_to_next_source(monkeypatch, tmp_path):
    e = _setup(monkeypatch, tmp_path)

    async def google(book):
        return _jpg("blue")

    monkeypatch.setattr(covers, "_google", google)
    r = FakeRedis()
    with Session(e) as s:
        book = s.get(SpokenBook, "b")
        s.expunge(book)
    assert covers.needs_cover(book, shared_with=3)
    assert asyncio.run(covers.fill(book, set())) == "folder"
    assert covers.own_path("b").is_file()
    r.kv["spoken:cover:src:b"] = "folder"
    assert asyncio.run(covers.reject(r, "b")) == "google"
    assert r.sets["spoken:cover:rejected:b"] == {"folder"}
    with Session(e) as s:
        assert s.get(SpokenBook, "b").cover_url.startswith("spoken/books/b/cover?v=")


def test_reject_without_other_source_leaves_placeholder(monkeypatch, tmp_path):
    e = _setup(monkeypatch, tmp_path)

    async def none(book):
        return None

    monkeypatch.setattr(covers, "_google", none)
    r = FakeRedis()
    r.sets["spoken:cover:rejected:b"] = {"folder"}
    assert asyncio.run(covers.reject(r, "b")) is None
    with Session(e) as s:
        assert s.get(SpokenBook, "b").cover_url is None


def test_custom_upload_is_never_replaced(monkeypatch, tmp_path):
    e = _setup(monkeypatch, tmp_path)
    r = FakeRedis()
    assert asyncio.run(covers.upload(r, "b", _jpg("green")))
    assert r.kv["spoken:cover:src:b"] == "custom"
    with Session(e) as s:
        book = s.get(SpokenBook, "b")
        s.expunge(book)
    assert not covers.needs_cover(book, shared_with=5)  # vlastní soubor existuje
    assert not asyncio.run(covers.upload(r, "b", b"not an image"))
