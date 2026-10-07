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
from app.models import SpokenBook, SpokenFile
from app.spoken import metadata, qbit, sktorrent, slsk_books
from app.spoken.importer import AUDIO, CATALOG, _natural, import_book
from app.utils import utcnow

logger = logging.getLogger(__name__)

# Cesta, kterou vidí qBittorrent i worker (stejný svazek na stejném místě).
SPOKEN_ROOT = Path(os.environ.get("SPOKEN_ROOT", "/data/spoken"))
# Torrent, který se v klientu do té doby ani neobjeví / nepohne, je chyba.
_LOST_AFTER = timedelta(minutes=15)


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
        "kind": book.kind or guess_kind(book.release_title or book.title),
    }


def guess_kind(title: str | None) -> str:
    """"drama" pro rozhlasovou hru / dramatizaci podle názvu, jinak "book"."""
    from app.spoken.catalog import parse_release

    return "drama" if title and parse_release(title)["drama"] else "book"


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
    share, state, retry, reason = await slsk_books.progress(data["user"], data["files"])
    if state == "failed":
        await _save(book.id, status="failed", error=reason or "Soulseek: stažení selhalo, zkus jinou verzi")
        return
    if state == "retry":
        # Přechodná chyba u části souborů: jen ty znovu do fronty.
        logger.info("kniha %s: znovu %d souborů ze Soulseeku", book.id, len(retry))
        await slsk_books.start(data["user"], retry)
        await _save(book.id, progress=round(share, 3))
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


# --- YouTube (celé video = kniha) --------------------------------------------
# Stahuje jeden worker (zámek v Redisu, obnovuje se průběhem); po restartu
# workeru zámek vyprší a stahování se v dalším kole spustí znovu.
_YT_LOCK_S = 120


async def _youtube_download(book_id: str, vid: str) -> None:
    from app.redis_bus import get_redis
    from app.spoken import youtube

    r = get_redis()
    loop = asyncio.get_running_loop()
    dest = SPOKEN_ROOT / book_id
    last = [0.0]

    def on_progress(share: float) -> None:
        if share - last[0] < 0.01:
            return
        last[0] = share
        asyncio.run_coroutine_threadsafe(_save(book_id, progress=round(share, 3)), loop)
        asyncio.run_coroutine_threadsafe(r.set(f"spoken:yt:lock:{book_id}", "1", ex=_YT_LOCK_S), loop)

    try:
        await asyncio.to_thread(youtube.download, vid, dest, on_progress)
        await _save(book_id, status="importing", progress=1.0)
        count = await asyncio.to_thread(import_book, book_id, dest)
        meta = await youtube.info(vid)
        chapters = (meta or {}).get("chapters") or []
        if chapters:
            # Kapitoly videa = kapitoly knihy (jeden soubor).
            def save_chapters() -> None:
                with Session(engine) as session:
                    for f in session.exec(select(SpokenFile).where(SpokenFile.book_id == book_id)).all():
                        f.chapters = chapters
                        session.add(f)
                    session.commit()

            await asyncio.to_thread(save_chapters)
        logger.info("kniha %s připravená z YouTube (%d soubor, %d kapitol)", book_id, count, len(chapters))
        await _save(book_id, status="ready", error=None, finished_at=utcnow(), storage_dir=str(dest))
    except Exception as e:  # noqa: BLE001
        logger.warning("youtube kniha %s: %s", book_id, e)
        await _save(book_id, status="failed", error="YouTube: video se nepodařilo stáhnout")
    finally:
        await r.delete(f"spoken:yt:lock:{book_id}")


async def _start_youtube(book: SpokenBook) -> None:
    from app.redis_bus import get_redis

    vid = (book.source_files or {}).get("video")
    if not vid:
        await _save(book.id, status="failed", error="chybí odkaz na video")
        return
    if not await get_redis().set(f"spoken:yt:lock:{book.id}", "1", nx=True, ex=_YT_LOCK_S):
        return  # stahuje jiný worker
    await _save(book.id, status="downloading", error=None)
    _yt_tasks[book.id] = asyncio.create_task(_youtube_download(book.id, vid))


_yt_tasks: dict[str, asyncio.Task] = {}


async def _start(book: SpokenBook) -> None:
    if book.source == "youtube":
        return await _start_youtube(book)
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
    wanted = indices if indices is not None else all_indices
    await qbit.set_priority(infohash, wanted, 1)
    # Poslouchat hned: popořadě, první kapitola napřed.
    audio = sorted(
        (f for f in sktorrent.torrent_files(torrent) if f["index"] in set(wanted) and f["path"].lower().endswith(tuple(AUDIO))),
        key=lambda f: _natural(f["path"]),
    )
    await qbit.start(infohash)
    await qbit.listen_early(infohash, audio[0]["index"] if audio else None)
    await _save(book.id, status="downloading", error=None, storage_dir=save_path)


def _imported_count(book_id: str) -> int:
    with Session(engine) as session:
        return len(session.exec(select(SpokenFile.id).where(SpokenFile.book_id == book_id)).all())


async def _follow_torrent(book: SpokenBook, t: dict) -> None:
    """Hotové kapitoly se importují průběžně -- první jde přehrát hned,
    jak dorazí, další přibývají; po poslední je kniha `ready`."""
    infohash = _infohash(book)
    indices = _indices(book)
    wanted = set(indices) if indices is not None else None
    files = [
        f for f in await qbit.files(infohash)
        if (wanted is None or f.get("index") in wanted) and str(f.get("name") or "").lower().endswith(tuple(AUDIO))
    ]
    if not files:
        await _save(book.id, status="failed", error="v torrentu není žádný zvuk")
        return
    total = sum(int(f.get("size") or 0) for f in files) or 1
    done_bytes = sum(int(f.get("size") or 0) * float(f.get("progress") or 0) for f in files)
    save = Path(str(t.get("save_path") or SPOKEN_ROOT / infohash))
    completed = [save / str(f["name"]) for f in files if float(f.get("progress") or 0) >= 1.0]
    all_done = len(completed) == len(files)
    if completed and (all_done or len(completed) > await asyncio.to_thread(_imported_count, book.id)):
        try:
            # Celé vydání na konci jako dřív (jeden formát), jinak hotové soubory.
            if all_done and indices is None and t.get("content_path"):
                await asyncio.to_thread(import_book, book.id, Path(str(t["content_path"])))
            else:
                await asyncio.to_thread(import_book, book.id, save, completed)
        except Exception as e:  # noqa: BLE001
            logger.exception("import knihy %s selhal", book.id)
            await _save(book.id, status="failed", error=f"import: {e}")
            return
    if all_done:
        logger.info("kniha %s připravená (%d souborů)", book.title, len(files))
        await _save(book.id, status="ready", progress=1.0, error=None, finished_at=utcnow())
    else:
        await _save(book.id, progress=round(min(done_bytes / total, 0.99), 3))


async def _follow(book: SpokenBook) -> None:
    if book.source == "youtube":
        # Běží (zámek drží worker, který stahuje) -- jinak (restart) znovu.
        return await _start_youtube(book)
    if book.source == "slskd":
        return await _follow_slskd(book)
    t = await qbit.info(_infohash(book))
    if t is not None:
        state = str(t.get("state") or "")
        if state in ("error", "missingFiles"):
            await _save(book.id, status="failed", error=f"torrent: {state}")
            return
        return await _follow_torrent(book, t)
    if t is None:
        created = book.created_at if book.created_at.tzinfo else book.created_at.replace(tzinfo=utcnow().tzinfo)
        if utcnow() - created > _LOST_AFTER:
            await _save(book.id, status="failed", error="torrent klient o knize neví")


async def enrich(r, limit: int = 3) -> None:
    """Název a autor z katalogu pro knihy, které to ještě nezkusily (nové
    i dřív stažené). Při chybě katalogu 10 minut pauza."""
    if await r.get("spoken:meta:backoff"):
        return

    def todo() -> list[SpokenBook]:
        with Session(engine) as session:
            books = list(session.exec(
                select(SpokenBook).where(SpokenBook.metadata_source.is_(None)).limit(limit)  # type: ignore[union-attr]
            ).all())
            for b in books:
                session.expunge(b)
            return books

    for book in await asyncio.to_thread(todo):
        try:
            hit = await metadata.lookup(book.release_title)
        except Exception as e:  # noqa: BLE001
            logger.warning("katalog audioknihy.cz: %s", e)
            await r.set("spoken:meta:backoff", "1", ex=600)
            return
        if hit is None:
            await _save(book.id, metadata_source="none")
        else:
            logger.info("kniha %r -> %r / %r", book.title, hit["title"], hit["author"])
            await _save(book.id, metadata_source=CATALOG, title=hit["title"], author=hit["author"])


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
        await enrich(r)
    finally:
        await r.delete("spoken:tick")
