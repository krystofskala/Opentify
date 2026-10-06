"""Stavový automat stahování knih -- worker ho posune o krok každých ~15 s
(app/worker.py, úklidová smyčka; zámek v Redisu = jen jeden worker naráz).
Bez vlastní fronty: stav je v DB, takže restart nic neztratí.

pending -> (přihlášení na SkTorrent, .torrent do qBittorrentu) -> downloading
downloading -> (qBittorrent hotovo) -> importing -> (mutagen) -> ready
Chybějící přihlášení není chyba: kniha čeká v `pending`, dokud se do .env
nedoplní, a pak se rozjede sama.
"""

from __future__ import annotations

import asyncio
import logging
import os
from datetime import timedelta
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.events import publish_event
from app.models import SpokenBook
from app.spoken import qbit, sktorrent, slsk_books
from app.spoken.importer import import_book
from app.utils import utcnow

logger = logging.getLogger(__name__)

# Cesta, kterou vidí qBittorrent i worker (stejný svazek na stejném místě).
SPOKEN_ROOT = Path(os.environ.get("SPOKEN_ROOT", "/data/spoken"))
# Torrent, který se v klientu do té doby ani neobjeví / nepohne, je chyba.
_LOST_AFTER = timedelta(minutes=15)
_DONE_STATES = {"uploading", "stalledUP", "pausedUP", "stoppedUP", "queuedUP", "forcedUP", "checkingUP"}


def book_out(book: SpokenBook) -> dict:
    return {
        "id": book.id,
        "title": book.title,
        "author": book.author,
        "narrator": book.narrator,
        "coverUrl": book.cover_url,
        "releaseTitle": book.release_title,
        "sizeBytes": book.size_bytes,
        "status": book.status,
        "progress": round(book.progress, 3),
        "error": book.error,
        "durationMs": book.duration_ms,
        "createdAt": book.created_at.isoformat() if book.created_at else None,
    }


async def _save(book_id: str, **fields) -> SpokenBook | None:
    def run() -> SpokenBook | None:
        with Session(engine) as session:
            book = session.get(SpokenBook, book_id)
            if book is None:
                return None
            changed = any(getattr(book, k) != v for k, v in fields.items())
            for k, v in fields.items():
                setattr(book, k, v)
            session.add(book)
            session.commit()
            session.refresh(book)
            session.expunge(book)
            return book if changed else None

    book = await asyncio.to_thread(run)
    if book is not None:
        await publish_event(book.requested_by_user_id, "spoken.book", book_out(book))
    return book


async def _start_slskd(book: SpokenBook) -> None:
    data = book.source_files or {}
    await slsk_books.start(data["user"], data["files"])
    await _save(book.id, status="downloading", error=None, storage_dir=str(SPOKEN_ROOT / book.id))


async def _follow_slskd(book: SpokenBook) -> None:
    data = book.source_files or {}
    share, state = await slsk_books.progress(data["user"], data["files"])
    if state == "failed":
        await _save(book.id, status="failed", error="Soulseek: stažení od tohoto uživatele selhalo, zkus jinou verzi")
        return
    if state != "done":
        await _save(book.id, progress=round(share, 3))
        return
    dest = SPOKEN_ROOT / book.id
    await _save(book.id, status="importing", progress=1.0)
    moved = await slsk_books.collect(data["files"], dest)
    if moved == 0:
        await _save(book.id, status="failed", error="stažené soubory se nenašly")
        return
    try:
        count = await asyncio.to_thread(import_book, book.id, dest)
    except Exception as e:  # noqa: BLE001
        logger.exception("import knihy %s selhal", book.id)
        await _save(book.id, status="failed", error=f"import: {e}")
        return
    logger.info("kniha %s připravená ze Soulseeku (%d souborů)", book.title, count)
    await _save(book.id, status="ready", error=None, finished_at=utcnow())


def _infohash(book: SpokenBook) -> str:
    """Kniha vybraná ze sbírky má vlastní source_ref; torrent je společný."""
    return (book.source_files or {}).get("infohash") or book.source_ref


def _indices(book: SpokenBook) -> list[int] | None:
    """Vybrané soubory sbírky (None = celý torrent)."""
    return (book.source_files or {}).get("indices")


async def _start(book: SpokenBook) -> None:
    if book.source == "slskd":
        return await _start_slskd(book)
    infohash, indices = _infohash(book), _indices(book)
    try:
        torrent = await sktorrent.download_torrent(infohash)
    except sktorrent.NotConfigured as e:
        await _save(book.id, error=str(e))
        return
    except PermissionError as e:
        await _save(book.id, error=str(e))
        return
    save_path = str(SPOKEN_ROOT / infohash)
    all_indices = [f["index"] for f in sktorrent.torrent_files(torrent)]
    if await qbit.info(infohash) is None:
        # Nový torrent: zastavený, jen vybrané soubory, pak spustit.
        await qbit.add(torrent, infohash, save_path, stopped=True)
        for _ in range(20):
            if await qbit.info(infohash) is not None:
                break
            await asyncio.sleep(0.5)
        if indices is not None:
            await qbit.set_priority(infohash, [i for i in all_indices if i not in set(indices)], 0)
    # Už stahovaná sbírka (jiná kniha z ní): jen přidat tyhle soubory.
    await qbit.set_priority(infohash, indices if indices is not None else all_indices, 1)
    await qbit.start(infohash)
    await _save(book.id, status="downloading", error=None, storage_dir=save_path)


async def _follow_selection(book: SpokenBook, t: dict, indices: list[int]) -> None:
    infohash = _infohash(book)
    wanted = set(indices)
    files = [f for f in await qbit.files(infohash) if f.get("index") in wanted]
    if not files:
        await _save(book.id, status="failed", error="vybrané soubory v torrentu nejsou")
        return
    total = sum(int(f.get("size") or 0) for f in files) or 1
    done = sum(int(f.get("size") or 0) * float(f.get("progress") or 0) for f in files)
    if any(float(f.get("progress") or 0) < 1.0 for f in files):
        await _save(book.id, progress=round(min(done / total, 0.99), 3))
        return
    save = Path(str(t.get("save_path") or SPOKEN_ROOT / infohash))
    paths = [save / str(f["name"]) for f in files]
    await _save(book.id, status="importing", progress=1.0)
    try:
        count = await asyncio.to_thread(import_book, book.id, save, paths)
    except Exception as e:  # noqa: BLE001
        logger.exception("import knihy %s selhal", book.id)
        await _save(book.id, status="failed", error=f"import: {e}")
        return
    logger.info("kniha %s připravená ze sbírky (%d souborů)", book.title, count)
    await _save(book.id, status="ready", error=None, finished_at=utcnow())


async def _follow(book: SpokenBook) -> None:
    if book.source == "slskd":
        return await _follow_slskd(book)
    t = await qbit.info(_infohash(book))
    if t is not None and _indices(book) is not None:
        state = str(t.get("state") or "")
        if state in ("error", "missingFiles"):
            await _save(book.id, status="failed", error=f"torrent: {state}")
            return
        return await _follow_selection(book, t, _indices(book))
    if t is None:
        created = book.created_at if book.created_at.tzinfo else book.created_at.replace(tzinfo=utcnow().tzinfo)
        if utcnow() - created > _LOST_AFTER:
            await _save(book.id, status="failed", error="torrent klient o knize neví")
        return
    state = str(t.get("state") or "")
    if state in ("error", "missingFiles"):
        await _save(book.id, status="failed", error=f"torrent: {state}")
        return
    progress = float(t.get("progress") or 0.0)
    if progress < 1.0 and state not in _DONE_STATES:
        await _save(book.id, progress=round(progress, 3))
        return
    root = Path(str(t.get("content_path") or book.storage_dir or SPOKEN_ROOT / book.source_ref))
    await _save(book.id, status="importing", progress=1.0)
    try:
        count = await asyncio.to_thread(import_book, book.id, root)
    except Exception as e:  # noqa: BLE001
        logger.exception("import knihy %s selhal", book.id)
        await _save(book.id, status="failed", error=f"import: {e}")
        return
    logger.info("kniha %s připravená (%d souborů)", book.title, count)
    await _save(book.id, status="ready", error=None, finished_at=utcnow())


async def tick(r) -> None:
    if not await r.set("spoken:tick", "1", nx=True, ex=60):
        return
    try:
        def open_books() -> list[SpokenBook]:
            with Session(engine) as session:
                books = list(session.exec(select(SpokenBook).where(SpokenBook.status.in_(["pending", "downloading", "importing"]))).all())  # type: ignore[attr-defined]
                for b in books:
                    session.expunge(b)
                return books

        for book in await asyncio.to_thread(open_books):
            try:
                if book.status == "pending":
                    await _start(book)
                else:
                    await _follow(book)
            except Exception as e:  # noqa: BLE001 -- jedna kniha nezastaví ostatní
                logger.warning("kniha %s: %s", book.id, e)
                await _save(book.id, error=str(e)[:300])
    finally:
        await r.delete("spoken:tick")
