"""Mluvené slovo (audioknihy) -- `/spoken/*`. Odděleně od hudby: vlastní
tabulky, vlastní stream, žádné poslechy (Listen), takže nic z toho
nepronikne do mixů, doporučení, Wrapped ani na ListenBrainz/Last.fm."""

from __future__ import annotations

from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel
from sqlmodel import Session, select

from app.auth import get_current_user
from app.db import get_session
from app.models import SpokenBook, SpokenFile, SpokenProgress
from app.spoken import sktorrent
from app.spoken.acquire import SPOKEN_ROOT, book_out
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


class AcquireIn(BaseModel):
    infohash: str
    title: str
    sizeBytes: int | None = None
    coverUrl: str | None = None


@spoken_router.post("/books", status_code=202)
def acquire(
    body: AcquireIn,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """"Stáhnout": jednorázově, jen na pokyn. Stejné vydání podruhé = stejná
    kniha (a její stav); po chybě se zkusí znovu."""
    infohash = body.infohash.strip().lower()
    if len(infohash) != 40 or any(c not in "0123456789abcdef" for c in infohash):
        raise HTTPException(status_code=422, detail="neplatný infohash")
    book = session.exec(select(SpokenBook).where(SpokenBook.source_ref == infohash)).first()
    if book is None:
        guess = guess_from_release(body.title)
        book = SpokenBook(
            source_ref=infohash,
            release_title=body.title[:300],
            title=guess["title"][:300],
            narrator=guess["narrator"],
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


@spoken_router.get("/books")
def books(session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    """Knihovna: všechny knihy na serveru (jako hudba), u každé moje pozice."""
    rows = session.exec(select(SpokenBook).order_by(SpokenBook.created_at.desc())).all()  # type: ignore[attr-defined]
    progress = {
        p.book_id: p
        for p in session.exec(select(SpokenProgress).where(SpokenProgress.user_id == current[0])).all()
    }
    out = []
    for b in rows:
        item = book_out(b)
        p = progress.get(b.id)
        item["progress"] = _progress_out(p) if p else None
        item["downloadProgress"] = round(b.progress, 3)
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
