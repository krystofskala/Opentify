"""Mluvené slovo (audioknihy) -- `/spoken/*`. Odděleně od hudby: vlastní
tabulky, vlastní stream, žádné poslechy (Listen), takže nic z toho
nepronikne do mixů, doporučení, Wrapped ani na ListenBrainz/Last.fm."""

from __future__ import annotations

import asyncio
import hashlib
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
from sqlmodel import Session, select

from app import download_limits
from app.auth import get_current_user
from app.db import get_session
from app.models import SpokenBook, SpokenFile, SpokenProgress
from app.public_access import deny_public
from app.spoken import sktorrent, slsk_books
from app.spoken.acquire import SPOKEN_ROOT, book_out
from app.spoken.importer import _natural as importer_natural
from app.spoken.importer import guess_from_release
from app.utils import utcnow

spoken_router = APIRouter(prefix="/spoken", tags=["spoken"])

_MEDIA_TYPES = {
    ".mp3": "audio/mpeg", ".m4a": "audio/mp4", ".m4b": "audio/mp4", ".aac": "audio/aac",
    ".flac": "audio/flac", ".ogg": "audio/ogg", ".opus": "audio/ogg", ".wma": "audio/x-ms-wma",
}


@spoken_router.get("/search")
async def search(q: str, session: Session = Depends(get_session)):
    """Vydání audioknih na SkTorrentu; u už stažených / stahovaných i `bookId`."""
    q = q.strip()
    if len(q) < 2:
        return {"releases": [], "loginConfigured": sktorrent.credentials() is not None}
    releases = await sktorrent.search(q)
    known = {
        b.source_ref: b
        for b in session.exec(
            select(SpokenBook).where(SpokenBook.source_ref.in_([r.infohash for r in releases]))  # type: ignore[attr-defined]
        ).all()
    }
    out = []
    for r in releases:
        item = r.to_json()
        book = known.get(r.infohash)
        if book is not None:
            item["bookId"] = book.id
            item["status"] = book.status
        out.append(item)
    return {"releases": out, "loginConfigured": sktorrent.credentials() is not None}


@spoken_router.get("/recommendations")
async def recommendations(current: tuple[str, str] = Depends(get_current_user)):
    """Domů mluveného slova: doporučené podcasty a audioknihy (6 h v mezipaměti)."""
    from app.catalog.cache import cached_json
    from app.spoken import recommend

    user_id = current[0]

    async def build() -> dict:
        podcasts, books = await asyncio.gather(recommend.podcasts_for(user_id), recommend.books_for(user_id))
        return {"podcasts": podcasts, "books": books}

    return await cached_json(
        f"spoken:recommendations:v1:{user_id}", 6 * 3600, build,
        is_empty=lambda d: not d["podcasts"] and not d["books"],
    )


@spoken_router.get("/search/foreign")
async def search_foreign(q: str, session: Session = Depends(get_session)):
    """Záloha: audioknihy ze Soulseeku (typicky anglické originály) --
    zvlášť, ať české výsledky ze SkTorrentu nečekají na pomalejší hledání."""
    q = q.strip()
    if len(q) < 2:
        return {"releases": []}
    releases = await slsk_books.search(q)
    known = {
        b.source_ref: b
        for b in session.exec(
            select(SpokenBook).where(SpokenBook.source_ref.in_([r["ref"] for r in releases]))  # type: ignore[attr-defined]
        ).all()
    }
    for r in releases:
        if book := known.get(r["ref"]):
            r["bookId"], r["status"] = book.id, book.status
    return {"releases": releases}


_AUDIO_EXT = (".mp3", ".m4a", ".m4b", ".flac", ".ogg", ".opus", ".aac", ".wma")


@spoken_router.get("/releases/{infohash}/files")
async def release_files(infohash: str):
    """Obsah vydání (sbírky) před stažením: zvukové soubory seskupené po
    knihách (složkách). Stažení .torrent chce účet -- přes VPN."""
    infohash = infohash.strip().lower()
    if len(infohash) != 40 or any(c not in "0123456789abcdef" for c in infohash):
        raise HTTPException(status_code=422, detail="neplatný infohash")
    try:
        torrent = await sktorrent.download_torrent(infohash)
    except sktorrent.NotConfigured as e:
        raise HTTPException(status_code=409, detail=str(e))
    files = [f for f in sktorrent.torrent_files(torrent) if f["path"].lower().endswith(_AUDIO_EXT)]
    groups: dict[str, dict] = {}
    for f in files:
        parts = f["path"].split("/")
        folder = parts[0] if len(parts) > 1 else ""
        g = groups.setdefault(folder, {"folder": folder, "size": 0, "files": []})
        g["size"] += f["size"]
        g["files"].append({"index": f["index"], "name": "/".join(parts[1:]) or parts[0], "size": f["size"]})
    return {"groups": sorted(groups.values(), key=lambda g: importer_natural(g["folder"]))}


@spoken_router.get("/releases/foreign/files")
async def foreign_release_files(ref: str):
    """Obsah vydání ze Soulseeku před stažením (složka z výsledku hledání;
    stahuje se celá)."""
    found = await slsk_books.cached(ref.strip())
    if found is None:
        raise HTTPException(status_code=409, detail="výsledek hledání vypršel, vyhledej knihu znovu")
    files = [
        {"index": i, "name": str(f["filename"]).replace("\\", "/").rsplit("/", 1)[-1], "size": int(f.get("size") or 0)}
        for i, f in enumerate(found["files"])
    ]
    return {"groups": [{"folder": "", "size": sum(f["size"] for f in files), "files": files}]}


class AcquireIn(BaseModel):
    infohash: str | None = None
    title: str
    sizeBytes: int | None = None
    coverUrl: str | None = None
    source: str = "sktorrent"  # sktorrent | slskd
    ref: str | None = None  # slskd: výsledek z /search/foreign
    # Sbírka: jen tyhle soubory (indexy z /releases/{infohash}/files) jako
    # jedna kniha; `folder` = její název.
    files: list[int] | None = None
    folder: str | None = None


@spoken_router.post("/books", status_code=202)
async def acquire(
    body: AcquireIn,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
    _local_only: None = Depends(deny_public),
):
    """"Stáhnout": jednorázově, jen na pokyn. Stejné vydání podruhé = stejná
    kniha (a její stav); po chybě se zkusí znovu."""
    # Limit audioknih na člověka (app/download_limits.py); admin bez limitu.
    await asyncio.to_thread(download_limits.check_book, current[0], body.sizeBytes)
    if body.source == "slskd":
        return await _acquire_slskd(body, session, current[0])
    infohash = (body.infohash or "").strip().lower()
    if len(infohash) != 40 or any(c not in "0123456789abcdef" for c in infohash):
        raise HTTPException(status_code=422, detail="neplatný infohash")
    selection = sorted({int(i) for i in body.files}) if body.files else None
    # Kniha vybraná ze sbírky: vlastní id podle vybraných souborů.
    ref = infohash if selection is None else (
        f"{infohash}:" + hashlib.sha1(",".join(map(str, selection)).encode()).hexdigest()[:12]
    )
    book = session.exec(select(SpokenBook).where(SpokenBook.source_ref == ref)).first()
    if book is None:
        guess = guess_from_release(body.folder or body.title)
        book = SpokenBook(
            source_ref=ref,
            source_files={"infohash": infohash, "indices": selection} if selection is not None else None,
            language="cs",
            release_title=body.title[:300],
            title=guess["title"][:300],
            narrator=guess["narrator"] or guess_from_release(body.title)["narrator"],
            size_bytes=body.sizeBytes,
            # Obal vždy přes náš server (viz `cover`), nic od klienta.
            cover_url=sktorrent.cover_path(infohash),
            requested_by_user_id=current[0],
        )
    elif book.status == "failed":
        book.status, book.error, book.progress, book.created_at = "pending", None, 0.0, utcnow()
    else:
        return book_out(book)
    session.add(book)
    session.commit()
    session.refresh(book)
    return book_out(book)


async def _acquire_slskd(body: AcquireIn, session: Session, user_id: str) -> dict:
    ref = (body.ref or "").strip()
    book = session.exec(select(SpokenBook).where(SpokenBook.source_ref == ref)).first() if ref else None
    if book is None:
        found = await slsk_books.cached(ref) if ref else None
        if found is None:
            raise HTTPException(status_code=409, detail="výsledek hledání vypršel, vyhledej knihu znovu")
        guess = guess_from_release(body.title)
        book = SpokenBook(
            source="slskd",
            source_ref=ref,
            source_files={"user": found["user"], "files": found["files"]},
            language="en",
            release_title=body.title[:300],
            title=guess["title"][:300],
            narrator=guess["narrator"],
            size_bytes=found["size"],
            requested_by_user_id=user_id,
        )
    elif book.status == "failed":
        book.status, book.error, book.progress, book.created_at = "pending", None, 0.0, utcnow()
    else:
        return book_out(book)
    session.add(book)
    session.commit()
    session.refresh(book)
    return book_out(book)


@spoken_router.get("/books")
def books(session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    """Knihovna: všechny knihy na serveru (jako hudba), u každé moje pozice."""
    rows = session.exec(select(SpokenBook).order_by(SpokenBook.created_at.desc())).all()  # type: ignore[attr-defined]
    progress = {
        p.book_id: p
        for p in session.exec(select(SpokenProgress).where(SpokenProgress.user_id == current[0])).all()
    }
    # Kolik částí už jde přehrát (stahuje se popořadě, první kapitola hned).
    playable: dict[str, int] = {}
    for book_id in session.exec(select(SpokenFile.book_id)).all():
        playable[book_id] = playable.get(book_id, 0) + 1
    out = []
    for b in rows:
        item = book_out(b)
        p = progress.get(b.id)
        item["progress"] = _progress_out(p) if p else None
        item["downloadProgress"] = round(b.progress, 3)
        item["playableFiles"] = playable.get(b.id, 0)
        out.append(item)
    return {"books": out}


def _progress_out(p: SpokenProgress) -> dict:
    return {
        "fileId": p.file_id,
        "positionMs": p.position_ms,
        "finished": p.finished,
        "updatedAt": p.updated_at.isoformat() if p.updated_at else None,
    }


@spoken_router.get("/books/{book_id}")
def book_detail(book_id: str, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    book = session.get(SpokenBook, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="kniha nenalezena")
    files = session.exec(select(SpokenFile).where(SpokenFile.book_id == book_id).order_by(SpokenFile.position)).all()  # type: ignore[arg-type]
    p = session.exec(
        select(SpokenProgress).where(SpokenProgress.user_id == current[0], SpokenProgress.book_id == book_id)
    ).first()
    return {
        **book_out(book),
        "files": [
            {"id": f.id, "position": f.position, "title": f.title, "durationMs": f.duration_ms, "chapters": f.chapters}
            for f in files
        ],
        "progress": _progress_out(p) if p else None,
    }


@spoken_router.get("/files/{file_id}/stream")
def stream_file(file_id: str, session: Session = Depends(get_session)):
    f = session.get(SpokenFile, file_id)
    if f is None:
        raise HTTPException(status_code=404, detail="soubor nenalezen")
    path = Path(f.path).resolve()
    # Jen soubory ze složky mluveného slova -- nic jiného z disku (i přes
    # "..", odkazy apod.: porovnává se skutečná cesta).
    if not path.is_relative_to(SPOKEN_ROOT.resolve()) or not path.is_file():
        raise HTTPException(status_code=404, detail="soubor chybí na disku")
    return FileResponse(path, media_type=_MEDIA_TYPES.get(path.suffix.lower(), "application/octet-stream"))


_COVER_CACHE = Path("/tmp/spoken-covers")


@spoken_router.get("/cover/{infohash}")
async def cover(infohash: str):
    """Obal vydání ze SkTorrentu přes server (Mullvad) -- telefon se na
    SkTorrent nikdy nepřipojuje sám. Uloží se do mezipaměti."""
    infohash = infohash.lower()
    if len(infohash) != 40 or any(c not in "0123456789abcdef" for c in infohash):
        raise HTTPException(status_code=404, detail="obal nenalezen")
    path = _COVER_CACHE / f"{infohash}.jpg"
    if not path.is_file():
        data = await sktorrent.fetch_cover(infohash)
        if data is None:
            raise HTTPException(status_code=404, detail="obal nenalezen")
        _COVER_CACHE.mkdir(parents=True, exist_ok=True)
        tmp = path.with_suffix(".part")
        tmp.write_bytes(data)
        tmp.replace(path)
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=604800"})


class ProgressIn(BaseModel):
    fileId: str
    positionMs: int
    finished: bool = False


@spoken_router.put("/books/{book_id}/progress")
def save_progress(
    book_id: str,
    body: ProgressIn,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    f = session.get(SpokenFile, body.fileId)
    if f is None or f.book_id != book_id:
        raise HTTPException(status_code=404, detail="soubor do knihy nepatří")
    p = session.exec(
        select(SpokenProgress).where(SpokenProgress.user_id == current[0], SpokenProgress.book_id == book_id)
    ).first() or SpokenProgress(user_id=current[0], book_id=book_id, file_id=body.fileId)
    p.file_id, p.position_ms, p.finished, p.updated_at = body.fileId, max(0, body.positionMs), body.finished, utcnow()
    session.add(p)
    session.commit()
    return {"ok": True}


def _failed_book(session: Session, book_id: str) -> SpokenBook:
    book = session.get(SpokenBook, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="kniha neexistuje")
    if book.status != "failed":
        raise HTTPException(status_code=409, detail="jde jen u knihy, jejíž stažení selhalo")
    return book


@spoken_router.post("/books/{book_id}/retry", status_code=202)
def retry(
    book_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
    _local_only: None = Depends(deny_public),
):
    """Nepovedené stažení znovu (stejné vydání, stejný výběr souborů)."""
    book = _failed_book(session, book_id)
    book.status, book.error, book.progress, book.created_at = "pending", None, 0.0, utcnow()
    session.add(book)
    session.commit()
    session.refresh(book)
    return book_out(book)


@spoken_router.delete("/books/{book_id}", status_code=204)
def remove_failed(book_id: str, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    """Odebrat knihu, jejíž stažení selhalo (hotové knihy se nemažou --
    jsou sdílené jako hudba)."""
    book = _failed_book(session, book_id)
    for row in session.exec(select(SpokenProgress).where(SpokenProgress.book_id == book_id)).all():
        session.delete(row)
    for row in session.exec(select(SpokenFile).where(SpokenFile.book_id == book_id)).all():
        session.delete(row)
    session.delete(book)
    session.commit()
