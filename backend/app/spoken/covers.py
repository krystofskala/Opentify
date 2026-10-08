"""Obaly audioknih: záložní řetěz, "Špatný obal" a vlastní obal (převzato
z hudby 8. 10., souhrn `mluvene-z-hudby-2026-10-08/souhrn.md` bod 6).

Kniha bez obalu, nebo se společným obalem s jinými knihami (díl z kompletu),
dostane vlastní -- první, co se najde:
  1. obal vložený v souboru (m4b/mp3, jako u hudby `_picture_bytes`),
  2. obrázek ve složce knihy (cover.jpg, folder.jpg…),
  3. Google Books (české vydání, stejný název a autor).
Uloží se trvale do `SPOKEN_ROOT/covers/<id>.jpg` (ne do složky torrentu,
ať se nerozbije sdílení), servíruje ho `/spoken/books/<id>/cover`.

"Špatný obal" ho zahodí a zdroj vynechá (zkusí se další). Vlastní nahraný
obal automatika nikdy nepřepíše.
"""

from __future__ import annotations

import asyncio
import logging
import time
from pathlib import Path

from sqlmodel import Session, func, select

from app.db import engine
from app.models import SpokenBook, SpokenFile

logger = logging.getLogger(__name__)

SOURCES = ("embedded", "folder", "google")
_IMAGE_NAMES = ("cover", "folder", "front", "obal", "obalka", "titul")
_IMAGE_EXT = (".jpg", ".jpeg", ".png", ".webp")


def own_path(book_id: str) -> Path:
    from app.spoken.acquire import SPOKEN_ROOT

    return SPOKEN_ROOT / "covers" / f"{book_id}.jpg"


def cover_url(book_id: str) -> str:
    # Verze v adrese: obal se cachuje na týden, nový by se jinak neukázal.
    return f"spoken/books/{book_id}/cover?v={int(time.time())}"


def _save(data: bytes, book_id: str) -> bool:
    from app.catalog.embedded_art import _save_resized

    dest = own_path(book_id)
    dest.parent.mkdir(parents=True, exist_ok=True)
    return _save_resized(data, dest)


def _files(book_id: str) -> list[Path]:
    with Session(engine) as session:
        rows = session.exec(select(SpokenFile.path).where(SpokenFile.book_id == book_id).order_by(SpokenFile.position)).all()
    return [Path(p) for p in rows if p]


def _embedded(book_id: str) -> bytes | None:
    from app.catalog.embedded_art import _picture_bytes

    for path in _files(book_id)[:3]:
        if path.is_file() and (data := _picture_bytes(str(path))):
            return data
    return None


def _folder(book_id: str) -> bytes | None:
    """Obrázek ve složce PRVNÍHO souboru knihy (u kompletu složka dílu, ne
    celého torrentu)."""
    files = _files(book_id)
    if not files:
        return None
    folder = files[0].parent
    try:
        images = [p for p in folder.iterdir() if p.is_file() and p.suffix.lower() in _IMAGE_EXT]
    except OSError:
        return None
    images.sort(key=lambda p: (not any(n in p.stem.lower() for n in _IMAGE_NAMES), p.name.lower()))
    for p in images[:3]:
        try:
            data = p.read_bytes()
        except OSError:
            continue
        if len(data) > 2000:
            return data
    return None


async def _google(book: SpokenBook) -> bytes | None:
    import tempfile

    from app.spoken.describe import cover_image

    if not book.author:
        return None
    with tempfile.TemporaryDirectory() as tmp:
        dest = Path(tmp) / "c.jpg"
        try:
            if await cover_image(book.title, book.author, dest):
                return dest.read_bytes()
        except Exception as e:  # noqa: BLE001 -- jen záloha
            logger.info("obal %s z Google Books: %s", book.id, e)
    return None


def needs_cover(book: SpokenBook, shared_with: int) -> bool:
    if own_path(book.id).is_file():
        return False
    return not book.cover_url or shared_with > 1


async def fill(book: SpokenBook, skip: set[str]) -> str | None:
    """Najde a uloží obal; vrací zdroj, nebo None (nic se nenašlo)."""
    for source in SOURCES:
        if source in skip:
            continue
        if source == "embedded":
            data = await asyncio.to_thread(_embedded, book.id)
        elif source == "folder":
            data = await asyncio.to_thread(_folder, book.id)
        else:
            data = await _google(book)
        if data and await asyncio.to_thread(_save, data, book.id):
            return source
    return None


async def tick(r, limit: int = 3) -> None:
    """Pár knih za kolo (worker, úloha řad mluveného slova)."""
    from app.spoken.acquire import _save as save_book

    def todo() -> list[tuple[SpokenBook, int]]:
        with Session(engine) as session:
            books = list(session.exec(select(SpokenBook).where(SpokenBook.status == "ready")).all())
            counts = dict(session.exec(
                select(SpokenBook.cover_url, func.count()).where(SpokenBook.cover_url.is_not(None)).group_by(SpokenBook.cover_url)  # type: ignore[union-attr]
            ).all())
            for b in books:
                session.expunge(b)
        return [(b, counts.get(b.cover_url, 0)) for b in books]

    done = 0
    for book, shared in await asyncio.to_thread(todo):
        if done >= limit:
            break
        if not await asyncio.to_thread(needs_cover, book, shared):
            continue
        if await r.get(f"spoken:cover:tried:{book.id}"):
            continue
        await r.set(f"spoken:cover:tried:{book.id}", "1", ex=7 * 24 * 3600)
        done += 1
        skip = {s.decode() if isinstance(s, bytes) else s for s in await r.smembers(f"spoken:cover:rejected:{book.id}")}
        source = await fill(book, skip)
        if source:
            await r.set(f"spoken:cover:src:{book.id}", source)
            logger.info("obal knihy %r: %s", book.title, source)
            await save_book(book.id, cover_url=cover_url(book.id))


async def reject(r, book_id: str) -> str | None:
    """"Špatný obal": vlastní obal pryč, jeho zdroj se vynechá a hned se zkusí
    další. Vrací nový zdroj, nebo None (zůstane bez obalu)."""
    from app.spoken.acquire import _save as save_book

    source = await r.get(f"spoken:cover:src:{book_id}")
    source = source.decode() if isinstance(source, bytes) else source
    if source and source != "custom":
        await r.sadd(f"spoken:cover:rejected:{book_id}", source)
    path = own_path(book_id)
    if path.is_file():
        path.unlink()
    await r.delete(f"spoken:cover:src:{book_id}")

    def load() -> SpokenBook | None:
        with Session(engine) as session:
            b = session.get(SpokenBook, book_id)
            if b is not None:
                session.expunge(b)
            return b

    book = await asyncio.to_thread(load)
    if book is None:
        return None
    skip = {s.decode() if isinstance(s, bytes) else s for s in await r.smembers(f"spoken:cover:rejected:{book_id}")}
    new = await fill(book, skip)
    if new:
        await r.set(f"spoken:cover:src:{book_id}", new)
        await save_book(book_id, cover_url=cover_url(book_id))
    else:
        # Bez obalu (zástupná ikona) -- i společný obal kompletu byl špatný.
        await save_book(book_id, cover_url=None)
    return new


async def upload(r, book_id: str, data: bytes) -> bool:
    from app.spoken.acquire import _save as save_book

    if not await asyncio.to_thread(_save, data, book_id):
        return False
    await r.set(f"spoken:cover:src:{book_id}", "custom")
    await save_book(book_id, cover_url=cover_url(book_id))
    return True
