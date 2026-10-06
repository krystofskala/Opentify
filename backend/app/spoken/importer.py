"""Stažená audiokniha -> `SpokenFile` řádky: pořadí souborů, délky, kapitoly
(m4b) a co se dá z tagů (název, autor, kdo čte)."""

from __future__ import annotations

import re
from pathlib import Path

import mutagen
from sqlmodel import Session, delete

from app.db import engine
from app.models import SpokenBook, SpokenFile

AUDIO = {".mp3", ".m4a", ".m4b", ".flac", ".ogg", ".opus", ".aac", ".wma"}
# Tagy, které nic neříkají (autor "Unknown" apod.).
_PLACEHOLDERS = {"unknown", "unknown artist", "neznámý", "various", "various artists", "-", "audiobook", "audiokniha"}


def _natural(text: str) -> list:
    # "2 - kapitola" před "10 - kapitola"
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", text)]


def _tag(audio, *keys: str) -> str | None:
    tags = getattr(audio, "tags", None)
    if not tags:
        return None
    for key in keys:
        try:
            value = tags.get(key)
        except (KeyError, ValueError, TypeError):
            value = None
        if value:
            value = value[0] if isinstance(value, list) else value
            text = str(value).strip()
            if text and text.lower() not in _PLACEHOLDERS:
                return text
    return None


def _track_no(audio) -> int:
    raw = _tag(audio, "tracknumber")
    try:
        return int(str(raw).split("/")[0]) if raw else 0
    except ValueError:
        return 0


def _chapters(path: Path) -> list[dict] | None:
    if path.suffix.lower() not in (".m4b", ".m4a"):
        return None
    try:
        from mutagen.mp4 import MP4

        chapters = getattr(MP4(path), "chapters", None)
    except Exception:  # noqa: BLE001 -- poškozený soubor kapitoly nemá
        return None
    if not chapters:
        return None
    return [{"title": str(c.title), "startMs": int(c.start * 1000)} for c in chapters]


def audio_files(root: Path) -> list[Path]:
    """Zvukové soubory knihy v JEDNOM formátu -- vydání někdy nese tutéž knihu
    víckrát (mp3 + ogg + m4b, 64kb verze) a vše by se přehrálo za sebou.
    m4b má přednost (kapitoly), jinak formát s nejvíc soubory (pak větší)."""
    if root.is_file():
        return [root] if root.suffix.lower() in AUDIO else []
    files = [p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in AUDIO]
    by_ext: dict[str, list[Path]] = {}
    for p in files:
        by_ext.setdefault(p.suffix.lower(), []).append(p)
    if len(by_ext) <= 1:
        chosen = files
    elif ".m4b" in by_ext:
        chosen = by_ext[".m4b"]
    else:
        chosen = max(by_ext.values(), key=lambda fs: (len(fs), sum(f.stat().st_size for f in fs)))
    # Tatáž nahrávka v nižší kvalitě vedle plné ("kniha_64kb.mp3" vedle "kniha.mp3").
    stems = {p.with_suffix("").as_posix() for p in chosen}
    return [p for p in chosen if not (p.stem.lower().endswith("_64kb") and p.with_suffix("").as_posix()[:-5] in stems)]


def import_book(book_id: str, root: Path) -> int:
    """Vrátí počet souborů. Pořadí: složky (CD1, CD2…) přirozeně, uvnitř číslo
    stopy z tagu, jinak přirozené řazení jmen."""
    files = audio_files(root)
    if not files:
        raise ValueError("ve stažených souborech není žádný zvuk")
    rows = []
    for p in files:
        try:
            audio = mutagen.File(p, easy=True)
        except Exception:  # noqa: BLE001
            audio = None
        rows.append((p, audio))
    rows.sort(key=lambda r: (_natural(str(r[0].parent)), _track_no(r[1]), _natural(r[0].name)))
    with Session(engine) as session:
        book = session.get(SpokenBook, book_id)
        if book is None:
            raise LookupError("kniha zmizela")
        session.exec(delete(SpokenFile).where(SpokenFile.book_id == book_id))  # type: ignore[arg-type]
        total = 0
        for i, (p, audio) in enumerate(rows):
            length = getattr(getattr(audio, "info", None), "length", None)
            duration = int(length * 1000) if length else None
            total += duration or 0
            session.add(
                SpokenFile(
                    book_id=book_id,
                    position=i,
                    path=str(p),
                    title=_tag(audio, "title") or p.stem,
                    duration_ms=duration,
                    chapters=_chapters(p),
                )
            )
        first = rows[0][1]
        # Album v tagu = název knihy (čistší než název vydání na trackeru).
        album = _tag(first, "album")
        if album and len(album) <= 200:
            book.title = album
        book.author = book.author or _tag(first, "albumartist", "artist")
        book.narrator = book.narrator or _tag(first, "performer", "composer")
        book.duration_ms = total or None
        book.storage_dir = str(root)
        session.add(book)
        session.commit()
    return len(rows)


_NARRATOR = re.compile(r"\(?\b(?:čte|cte|číta|cita|načetl|nacetl|interpret)\s*:?\s*([^()\[\]]+?)\s*[)\]]?(?:$|[(\[])", re.I)


def guess_from_release(title: str) -> dict:
    """Z názvu vydání ("Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner")
    co nejvíc: kdo čte, jinak jen očištěný název. Autora / titul nerozlišuje
    (pořadí na trackeru se liší) -- doplní je tagy souborů."""
    narrator = None
    m = _NARRATOR.search(title)
    if m:
        narrator = m.group(1).strip(" -,")
    clean = re.sub(r"[(\[][^)\]]*[)\]]", "", title)
    clean = _NARRATOR.sub("", clean)
    clean = re.sub(r"\s+", " ", clean).strip(" -,")
    return {"title": clean or title, "narrator": narrator}
