"""Mluvené slovo (audioknihy) -- `/spoken/*`. Odděleně od hudby: vlastní
tabulky, vlastní stream, žádné poslechy (Listen), takže nic z toho
nepronikne do mixů, doporučení, Wrapped ani na ListenBrainz/Last.fm."""

from __future__ import annotations

import asyncio
import hashlib
import re
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import FileResponse
from pydantic import BaseModel
from sqlmodel import Session, select

from app import download_limits, download_requests
from app.auth import get_current_user
from app.db import get_session
from app.models import SpokenBook, SpokenFavorite, SpokenFile, SpokenProgress
from app.public_access import deny_public, is_public
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
    # Odkaz na video z YouTube (audiokniha, rozhlasová hra): to jedno video.
    from app.spoken import youtube

    if vid := youtube.video_id(q):
        meta = await youtube.info(vid)
        if meta is None:
            return {"releases": [], "loginConfigured": True}
        known = session.exec(select(SpokenBook).where(SpokenBook.source_ref == f"yt:{vid}")).first()
        hours, minutes = divmod(meta["durationS"] // 60, 60)
        item = {
            "source": "youtube", "ref": youtube.watch_url(vid), "infohash": "",
            "title": meta["title"], "sizeBytes": meta["sizeBytes"], "seeders": 1, "files": 1,
            "uploader": meta["uploader"], "durationText": f"{hours} h {minutes} min" if hours else f"{minutes} min",
        }
        if known is not None:
            item["bookId"], item["status"] = known.id, known.status
        return {"releases": [item], "loginConfigured": True}
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
    from app.spoken.youtube import video_id

    if len(q) < 2 or video_id(q):  # odkaz na YouTube řeší /search
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


@spoken_router.get("/search/rozhlas")
async def search_rozhlas(q: str, session: Session = Depends(get_session)):
    """Archiv Českého rozhlasu (mujrozhlas.cz): četba a rozhlasové hry, které
    jdou právě stáhnout. Zvlášť, ať ostatní hledání nečeká."""
    from app.spoken import rozhlas
    from app.spoken.youtube import video_id

    q = q.strip()
    if len(q) < 2 or video_id(q):
        return {"releases": []}
    try:
        releases = [rozhlas.public(r) for r in await rozhlas.search(q)]
    except Exception as e:  # noqa: BLE001 -- výpadek rozhlasu nesmí shodit hledání
        raise HTTPException(status_code=502, detail="Český rozhlas teď neodpovídá") from e
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


@spoken_router.get("/releases/rozhlas/files")
async def rozhlas_release_files(ref: str):
    """Obsah vydání z Českého rozhlasu: díly, které jdou stáhnout."""
    from app.spoken import rozhlas

    rel = await rozhlas.release(ref.strip()) if rozhlas.is_ref(ref.strip()) else None
    if rel is None:
        raise HTTPException(status_code=404, detail="pořad už není k poslechu")
    names = rozhlas.part_titles(rel["title"], rel["episodes"])
    files = [{"index": i, "name": names[i], "size": int(ep.get("size") or 0)} for i, ep in enumerate(rel["episodes"])]
    return {"groups": [{"folder": "", "size": sum(f["size"] for f in files), "files": files}]}


_AUDIO_EXT = (".mp3", ".m4a", ".m4b", ".flac", ".ogg", ".opus", ".aac", ".wma")


@spoken_router.get("/releases/youtube/files")
async def youtube_release_files(ref: str):
    """Obsah "vydání" z YouTube: jedno video (a jeho kapitoly)."""
    from app.spoken import youtube

    vid = youtube.video_id(ref)
    meta = await youtube.info(vid) if vid else None
    if meta is None:
        raise HTTPException(status_code=404, detail="video se nepodařilo načíst")
    size = int(meta["sizeBytes"] or 0)
    return {"groups": [{"folder": "", "size": size, "files": [{"index": 0, "name": meta["title"], "size": size}]}]}


# Musí být PŘED `/releases/{infohash}/files` -- jinak FastAPI vezme
# "foreign" jako infohash a obsah vydání ze Soulseeku se nikdy nenačte
# (422, nahlášeno 7. 10.: "Obsah vydání se nepodařilo načíst").
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


class AcquireIn(BaseModel):
    infohash: str | None = None
    title: str
    sizeBytes: int | None = None
    coverUrl: str | None = None
    source: str = "sktorrent"  # sktorrent | slskd | youtube | rozhlas
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
    request: Request = None,  # type: ignore[assignment]  -- None jen v testech
):
    """"Stáhnout": jednorázově, jen na pokyn. Stejné vydání podruhé = stejná
    kniha (a její stav); po chybě se zkusí znovu. Když stažení musí schválit
    správce (velké vydání, z internetu, přes týdenní limit -- viz
    app/download_limits.py), založí se žádost a vrátí se
    `{"status": "awaiting_approval"}`."""
    user_id = current[0]
    ref = _book_ref(body)
    book = session.exec(select(SpokenBook).where(SpokenBook.source_ref == ref)).first()
    if book is not None and book.status != "failed":
        return book_out(book)  # už je / stahuje se -- nic nového
    found = None
    size = body.sizeBytes
    if body.source == "slskd":
        found = await slsk_books.cached(ref)
        if found is None:
            raise HTTPException(status_code=409, detail="výsledek hledání vypršel, vyhledej knihu znovu")
        size = found["size"]
    elif body.source == "rozhlas":
        from app.spoken import rozhlas

        rel = await rozhlas.release(ref)
        if rel is None:
            raise HTTPException(status_code=404, detail="pořad už není k poslechu")
        size = rel["sizeBytes"]
    public = request is not None and is_public(request)
    reason = await asyncio.to_thread(download_limits.book_approval_reason, user_id, size, public=public)
    if reason:
        return await asyncio.to_thread(
            download_requests.create, user_id, body.model_dump(), found, size, reason, _public_base(request)
        )
    return await acquire_now(body, session, user_id, found)


def _public_base(request: Request | None) -> str:
    """Adresa serveru pro tlačítka v upozornění (z `.env`, jinak z požadavku)."""
    import os

    base = os.environ.get("OPENTIFY_PUBLIC_URL", "").strip().rstrip("/")
    if base:
        return base
    return str(request.base_url).rstrip("/") if request is not None else ""


def _book_ref(body: AcquireIn) -> str:
    """Id vydání: infohash (u výběru ze sbírky + otisk výběru), u Soulseeku ref,
    u YouTube "yt:<id videa>"."""
    if body.source == "youtube":
        from app.spoken.youtube import video_id

        vid = video_id(body.ref)
        if not vid:
            raise HTTPException(status_code=422, detail="neplatný odkaz na YouTube")
        return f"yt:{vid}"
    if body.source == "rozhlas":
        from app.spoken.rozhlas import is_ref

        ref = (body.ref or "").strip()
        if not is_ref(ref):
            raise HTTPException(status_code=422, detail="neplatný pořad Českého rozhlasu")
        return ref
    if body.source == "slskd":
        ref = (body.ref or "").strip()
        if not ref:
            raise HTTPException(status_code=409, detail="výsledek hledání vypršel, vyhledej knihu znovu")
        return ref
    infohash = (body.infohash or "").strip().lower()
    if len(infohash) != 40 or any(c not in "0123456789abcdef" for c in infohash):
        raise HTTPException(status_code=422, detail="neplatný infohash")
    selection = sorted({int(i) for i in body.files}) if body.files else None
    # Kniha vybraná ze sbírky: vlastní id podle vybraných souborů.
    return infohash if selection is None else (
        f"{infohash}:" + hashlib.sha1(",".join(map(str, selection)).encode()).hexdigest()[:12]
    )


async def acquire_now(body: AcquireIn, session: Session, user_id: str, found: dict | None = None) -> dict:
    """Založit (nebo po chybě obnovit) stahování -- bez kontroly limitů
    (volá se po rozhodnutí: hned, nebo po schválení žádosti)."""
    ref = _book_ref(body)
    book = session.exec(select(SpokenBook).where(SpokenBook.source_ref == ref)).first()
    if book is None and body.source == "youtube":
        from app.spoken.youtube import video_id

        vid = video_id(body.ref)
        guess = guess_from_release(body.title)
        book = SpokenBook(
            source="youtube",
            source_ref=ref,
            source_files={"video": vid},
            release_title=body.title[:300],
            title=guess["title"][:300],
            narrator=guess["narrator"],
            size_bytes=body.sizeBytes,
            requested_by_user_id=user_id,
        )
    elif book is None and body.source == "rozhlas":
        from app.spoken import rozhlas

        rel = await rozhlas.release(ref)
        if rel is None:
            raise HTTPException(status_code=404, detail="pořad už není k poslechu")
        fields = rozhlas.book_fields(rel)
        book = SpokenBook(
            source="rozhlas",
            source_ref=ref,
            source_files={k: rel.get(k) for k in ("title", "coverUrl", "description", "kind", "episodes")},
            language="cs",
            release_title=rel["title"][:300],
            title=fields["title"],
            author=fields["author"],
            narrator=fields["narrator"],
            kind=fields["kind"],
            description=fields["description"],
            # Katalog audioknihy.cz rozhlasové pořady nezná -- název je z rozhlasu.
            metadata_source="rozhlas",
            size_bytes=rel["sizeBytes"],
            requested_by_user_id=user_id,
        )
    elif book is None:
        if body.source == "slskd":
            if found is None:
                found = await slsk_books.cached(ref)
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
        else:
            infohash = (body.infohash or "").strip().lower()
            selection = sorted({int(i) for i in body.files}) if body.files else None
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


class SpokenLayoutIn(BaseModel):
    order: list[str]
    hidden: list[str] = []


@spoken_router.get("/home/layout")
def spoken_home_layout(current: tuple[str, str] = Depends(get_current_user)):
    """Sekce Domů mluveného slova v pořadí profilu, i se skrytými."""
    from app.spoken import home_layout

    return {"sections": home_layout.entries(current[0])}


@spoken_router.put("/home/layout")
def set_spoken_home_layout(body: SpokenLayoutIn, current: tuple[str, str] = Depends(get_current_user)):
    from app.spoken import home_layout

    return {"sections": home_layout.save(current[0], body.order, body.hidden)}


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
    return {"books": _book_items(rows, progress, playable, current[0])}


def _favorite_books(user_id: str) -> set[str]:
    from app.db import engine

    with Session(engine) as session:
        return set(session.exec(
            select(SpokenFavorite.ref).where(SpokenFavorite.user_id == user_id, SpokenFavorite.kind == "book")
        ).all())


def _book_items(rows, progress: dict, playable: dict[str, int], user_id: str) -> list[dict]:
    admin = download_limits.is_admin(user_id)
    favorites = _favorite_books(user_id)
    out = []
    for b in rows:
        # Nepovedené stažení vidí jen ten, kdo o knihu žádal (a správce) --
        # ostatním by v „Stahuje se“ strašila cizí chyba (UX audit 7. 10.).
        if b.status == "failed" and not admin and b.requested_by_user_id != user_id:
            continue
        item = book_out(b)
        p = progress.get(b.id)
        item["progress"] = _progress_out(p) if p else None
        item["downloadProgress"] = round(b.progress, 3)
        item["playableFiles"] = playable.get(b.id, 0)
        # Moje = o knihu jsem žádal, nebo ji poslouchám. Ostatní knihy na
        # serveru má Domů ve vlastní sekci (pustit hned, bez stahování).
        # + srdíčko: knihu si uložil do svých, i když ji ještě neposlouchá.
        item["favorite"] = b.id in favorites
        item["mine"] = b.requested_by_user_id == user_id or p is not None or item["favorite"]
        out.append(item)
    return out


def _fold(text: str | None) -> str:
    import unicodedata

    text = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().casefold()
    return " ".join(text.split())


def _names(field: str | None) -> list[str]:
    """"Zdeněk Jirotka a Josef Hrubín" -> jednotlivá jména (bez diakritiky).
    Čárka jméno nedělí ("Jirotka, Zdeněk" je jeden člověk) -- obě pořadí."""
    import re

    out: list[str] = []
    for n in re.split(r"\s*(?:;|&|/|\ba\b|\band\b)\s*", field or ""):
        if not n.strip():
            continue
        out.append(_fold(n))
        if "," in n:  # "Jirotka, Zdeněk" -> i "Zdeněk Jirotka"
            last, _, first = n.partition(",")
            out.append(_fold(f"{first} {last}"))
    return out


@spoken_router.get("/series")
async def series(title: str, author: str, current: tuple[str, str] = Depends(get_current_user)):
    """Řada knihy a pořadí čtení (Wikidata, 30 dní v mezipaměti) a u každého
    dílu, co je na serveru a jak daleko jsi. Nic nenalezeno / Wikidata
    nedostupná = `{"series": null}` (appka řadu prostě neukáže)."""
    from app.spoken import series as series_mod

    title, author = title.strip(), author.strip()
    if len(title) < 2 or len(author) < 2:
        return {"series": None}
    try:
        found = await series_mod.lookup(title, author)
    except Exception as e:  # noqa: BLE001 -- 429 / výpadek Wikidat: bez řady, nic se neuloží
        import logging

        logging.getLogger(__name__).info("řada %r / %r: %s", title, author, e)
        return {"series": None}
    if found is None:
        return {"series": None}
    return {"series": await asyncio.to_thread(series_mod.with_library, found, current[0])}


@spoken_router.get("/series/collections")
async def series_collections(name: str, author: str, session: Session = Depends(get_session)):
    """Celá řada ke stažení: komplety / sbírky ze SkTorrentu ("Zaklínač
    komplet", "Harry Potter 1-7"). Výběr knih z nich je stejný jako u každé
    sbírky (obsah vydání)."""
    from app.spoken.catalog import fold, parse_release
    from app.spoken.series import _surname

    name, author = name.strip(), author.strip()
    if len(name) < 2:
        return {"releases": []}
    try:
        releases = await sktorrent.search(f"{name} {_surname(author)}".strip())
    except Exception:  # noqa: BLE001
        return {"releases": []}
    want = fold(name)
    # Komplet: "komplet / sbírka / trilogie", rozsah dílů ("1-7", "I.-VIII.") nebo přes 2 GB.
    span = re.compile(r"\b(?:\d{1,2}|[ivx]{1,4})\s*\.?\s*[-–]\s*(?:\d{1,2}|[ivx]{1,4})\b", re.I)
    picked = [
        r for r in releases
        if want in fold(r.title)
        and (parse_release(r.title)["collection"] or span.search(r.title) or (r.size_bytes or 0) > 2 * 1024**3)
    ]
    known = {
        b.source_ref: b
        for b in session.exec(select(SpokenBook).where(SpokenBook.source_ref.in_([r.infohash for r in picked]))).all()  # type: ignore[attr-defined]
    }
    out = []
    for r in picked:
        item = r.to_json()
        if book := known.get(r.infohash):
            item["bookId"], item["status"] = book.id, book.status
        out.append(item)
    return {"releases": out}


@spoken_router.get("/work")
async def work(title: str, author: str, current: tuple[str, str] = Depends(get_current_user)):
    """Stránka knihy: kniha z Knihovny.cz a všechna její vydání (SkTorrent
    + kopie na serveru), doporučené nahoře s důvodem. Hodina v mezipaměti."""
    from app.catalog.cache import cached_json
    from app.spoken import works
    from app.spoken.catalog import fold

    title, author = title.strip(), author.strip()
    if len(title) < 2 or len(author) < 2:
        raise HTTPException(status_code=400, detail="Chybí název nebo autor.")

    async def build() -> dict:
        return {"page": await works.work_page(title, author, current[0])}

    out = await cached_json(f"spoken:work:v1:{current[0]}:{fold(title)}:{fold(author)}", 3600, build,
                            is_empty=lambda d: d.get("page") is None)
    if out.get("page") is None:
        raise HTTPException(status_code=404, detail="Knihu jsme v katalogu nenašli.")
    return out["page"]


def person_ref(name: str, role: str) -> str:
    """Bez diakritiky i interpunkce ("J. R. R. Tolkien" -> "j r r tolkien")
    -- stejně skládá appka (`spokenPersonRef`)."""
    from app.spoken.catalog import fold

    return f"{'narrator' if role == 'narrator' else 'author'}:{fold(name)}"


class FavoriteIn(BaseModel):
    kind: str  # book | person
    ref: str | None = None  # id knihy
    name: str | None = None  # osoba
    role: str = "author"
    on: bool = True


@spoken_router.get("/favorites")
def favorites(session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    """Srdíčka profilu: celé knihy a autoři / interpreti."""
    rows = session.exec(select(SpokenFavorite).where(SpokenFavorite.user_id == current[0])).all()
    return {
        "books": [r.ref for r in rows if r.kind == "book"],
        "people": [{"ref": r.ref, "name": r.name} for r in rows if r.kind == "person"],
    }


@spoken_router.put("/favorites")
def set_favorite(body: FavoriteIn, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    if body.kind == "book":
        if not body.ref or session.get(SpokenBook, body.ref) is None:
            raise HTTPException(status_code=404, detail="kniha nenalezena")
        ref, name = body.ref, None
    elif body.kind == "person":
        if not body.name or len(body.name.strip()) < 2:
            raise HTTPException(status_code=400, detail="Chybí jméno.")
        ref, name = person_ref(body.name, body.role), body.name.strip()
    else:
        raise HTTPException(status_code=400, detail="Neznámý druh.")
    existing = session.exec(select(SpokenFavorite).where(
        SpokenFavorite.user_id == current[0], SpokenFavorite.kind == body.kind, SpokenFavorite.ref == ref
    )).all()
    if body.on and not existing:
        session.add(SpokenFavorite(user_id=current[0], kind=body.kind, ref=ref, name=name))
    if not body.on:
        for row in existing:
            session.delete(row)
    session.commit()
    return favorites(session=session, current=current)


@spoken_router.get("/search/local")
async def search_local(
    q: str, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)
):
    """Hledání v tom, co už je na serveru: knihy (název, autor, kdo čte) a
    autoři / interpreti. Když se dotaz shoduje se spisovatelem na Wikidatech
    a na serveru od něj nic není, je mezi autory i tak (jeho stránka nabídne
    stažení)."""
    from app.spoken import people

    words = _fold(q).split()
    if not words or len(q.strip()) < 2:
        return {"books": [], "people": []}
    rows = session.exec(select(SpokenBook).order_by(SpokenBook.created_at.desc())).all()  # type: ignore[attr-defined]

    def hit(*texts: str | None) -> bool:
        text = " ".join(_fold(t) for t in texts if t)
        return all(w in text for w in words)

    matched = [b for b in rows if hit(b.title, b.author, b.narrator)]
    found: dict[tuple[str, str], dict] = {}
    for b in rows:
        for role, name in (("author", b.author), ("narrator", b.narrator)):
            if name and hit(name):
                # "Jirotka, Zdeněk" a "Zdeněk Jirotka" je jeden člověk.
                key = sorted(people.name_variants(name), key=lambda v: "," in v)[0]
                entry = found.setdefault((role, key), {"name": name, "role": role, "books": 0})
                if "," in entry["name"] and "," not in name:
                    entry["name"] = name
                entry["books"] += 1
    persons = sorted(found.values(), key=lambda p: (p["role"] != "author", -p["books"]))[:8]
    if not any(p["role"] == "author" for p in persons) and len(words) >= 2:
        wiki = await people.wiki_person(q.strip(), "author")
        if wiki:
            persons.insert(0, {"name": q.strip(), "role": "author", "books": 0, "image": wiki.get("image")})
    ids = [b.id for b in matched[:20]]
    progress = {
        p.book_id: p
        for p in session.exec(
            select(SpokenProgress).where(SpokenProgress.user_id == current[0], SpokenProgress.book_id.in_(ids))  # type: ignore[attr-defined]
        ).all()
    } if ids else {}
    return {"books": _book_items(matched[:20], progress, {}, current[0]), "people": persons}


@spoken_router.get("/person/wiki")
async def person_wiki(name: str, role: str = "author", _current=Depends(get_current_user)):
    """Jen fotka a medailonek (Wikidata / Wikipedie) -- pro náhledy autorů."""
    from app.spoken import people

    wiki = await people.wiki_person(name.strip(), role)
    return {"image": wiki.get("image"), "description": wiki.get("description")}


@spoken_router.get("/person")
async def person(
    name: str,
    role: str = "author",
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Stránka autora / interpreta (čte): jeho knihy na serveru a další
    vydání na SkTorrentu ke stažení (u už stažených `bookId`)."""
    name = name.strip()
    if len(name) < 2:
        raise HTTPException(status_code=400, detail="Chybí jméno.")
    field = SpokenBook.narrator if role == "narrator" else SpokenBook.author
    wanted = _fold(name)
    rows = [
        b
        for b in session.exec(
            select(SpokenBook).where(field.is_not(None)).order_by(SpokenBook.created_at.desc())  # type: ignore[union-attr,attr-defined]
        ).all()
        if wanted in _names(b.narrator if role == "narrator" else b.author)
    ]
    ids = [b.id for b in rows]
    progress = {
        p.book_id: p
        for p in session.exec(
            select(SpokenProgress).where(SpokenProgress.user_id == current[0], SpokenProgress.book_id.in_(ids))  # type: ignore[attr-defined]
        ).all()
    } if ids else {}
    playable: dict[str, int] = {}
    for book_id in session.exec(select(SpokenFile.book_id).where(SpokenFile.book_id.in_(ids))).all() if ids else []:  # type: ignore[attr-defined]
        playable[book_id] = playable.get(book_id, 0) + 1
    books = _book_items(rows, progress, playable, current[0])

    from app.spoken import people

    async def search() -> list:
        try:
            return await sktorrent.search(name)
        except Exception:  # noqa: BLE001 - SkTorrent nedostupný: stránka i tak ukáže knihy na serveru
            return []

    # Fotka a medailonek z Wikidat / Wikipedie (jako u interpretů hudby).
    releases, wiki = await asyncio.gather(search(), people.wiki_person(name, role))
    on_server = {b.source_ref: b for b in rows}
    known = {
        b.source_ref: b
        for b in session.exec(
            select(SpokenBook).where(SpokenBook.source_ref.in_([r.infohash for r in releases]))  # type: ignore[attr-defined]
        ).all()
    } if releases else {}
    out = []
    for r in releases:
        if r.infohash in on_server:
            continue  # už je výš v "Na serveru"
        item = r.to_json()
        book = known.get(r.infohash)
        if book is not None:
            item["bookId"] = book.id
            item["status"] = book.status
        out.append(item)
    return {
        "name": name,
        "role": "narrator" if role == "narrator" else "author",
        "books": books,
        "releases": out[:40],
        "image": wiki.get("image"),
        "bio": wiki.get("bio"),
        "description": wiki.get("description"),
        "loginConfigured": sktorrent.credentials() is not None,
    }


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


@spoken_router.get("/books/{book_id}/description")
async def book_description(book_id: str, session: Session = Depends(get_session), _current=Depends(get_current_user)):
    """Popis knihy (Google Books, jen jistá shoda) -- zvlášť, ať na něj detail nečeká."""
    from app.spoken import describe

    book = session.get(SpokenBook, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="kniha nenalezena")
    if book.description:  # z vydání (YouTube popis videa)
        return {"description": book.description}
    return {"description": await describe.describe(book.title, book.author)}


@spoken_router.get("/books/{book_id}/cover")
def book_cover(book_id: str, session: Session = Depends(get_session)):
    """Obal uložený u knihy (náhled videa z YouTube)."""
    book = session.get(SpokenBook, book_id)
    # Vlastní obal knihy (díl z kompletu, `series_link`) má přednost.
    own = SPOKEN_ROOT / "covers" / f"{book_id}.jpg"
    if book is not None and own.is_file():
        return FileResponse(own, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=604800"})
    path = Path(book.storage_dir) / "cover.jpg" if book is not None and book.storage_dir else None
    if path is None or not path.is_file():
        raise HTTPException(status_code=404, detail="obal nenalezen")
    return FileResponse(path, media_type="image/jpeg", headers={"Cache-Control": "private, max-age=604800"})


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


def _failed_book(session: Session, book_id: str, user_id: str) -> SpokenBook:
    book = session.get(SpokenBook, book_id)
    if book is None or (book.requested_by_user_id != user_id and not download_limits.is_admin(user_id)):
        raise HTTPException(status_code=404, detail="kniha neexistuje")
    if book.status != "failed":
        raise HTTPException(status_code=409, detail="jde jen u knihy, jejíž stažení selhalo")
    return book


class KindIn(BaseModel):
    kind: str  # book | drama


@spoken_router.put("/books/{book_id}/kind")
async def set_kind(
    book_id: str,
    body: KindIn,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
    _local_only: None = Depends(deny_public),
):
    """Ručně: audiokniha, nebo rozhlasová hra (odhad z názvu se může plést).
    Kniha je společná, takže to platí pro všechny profily."""
    if body.kind not in ("book", "drama"):
        raise HTTPException(status_code=400, detail="Neznámý druh.")
    book = session.get(SpokenBook, book_id)
    if book is None:
        raise HTTPException(status_code=404, detail="kniha nenalezena")
    book.kind = body.kind
    session.add(book)
    session.commit()
    session.refresh(book)
    from app.events import publish_event

    out = book_out(book)
    await publish_event(current[0], "spoken.book", out)
    return out


@spoken_router.post("/books/{book_id}/retry", status_code=202)
def retry(
    book_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
    _local_only: None = Depends(deny_public),
):
    """Nepovedené stažení znovu (stejné vydání, stejný výběr souborů)."""
    book = _failed_book(session, book_id, current[0])
    book.status, book.error, book.progress, book.created_at = "pending", None, 0.0, utcnow()
    session.add(book)
    session.commit()
    session.refresh(book)
    return book_out(book)


@spoken_router.delete("/books/{book_id}", status_code=204)
def remove_failed(book_id: str, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    """Odebrat knihu, jejíž stažení selhalo (hotové knihy se nemažou --
    jsou sdílené jako hudba)."""
    book = _failed_book(session, book_id, current[0])
    for row in session.exec(select(SpokenProgress).where(SpokenProgress.book_id == book_id)).all():
        session.delete(row)
    for row in session.exec(select(SpokenFile).where(SpokenFile.book_id == book_id)).all():
        session.delete(row)
    session.delete(book)
    session.commit()
