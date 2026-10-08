"""Stažená audiokniha -> `SpokenFile` řádky: pořadí souborů, délky, kapitoly
(m4b) a co se dá z tagů (název, autor, kdo čte)."""

from __future__ import annotations

import re
import unicodedata
from pathlib import Path

import mutagen
from sqlmodel import Session, select

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


def _fold(text: str) -> str:
    return re.sub(r"[\W_]+", "", unicodedata.normalize("NFC", text)).casefold()


def fix_title_encoding(title: str, stem: str) -> str:
    """Tag uložený ve Windows-1250, přečtený jako Latin-1 ("Zaklínaè",
    "svìta", "ž" jako řídicí znak 0x9E). Stejná oprava jako u hudby
    (`rebuild_own_library.fix_text`): silné znaky vždy, samotné "è" jen když
    opravený text líp sedí na název souboru (francouzské "Crème" zůstane).
    Dřív jen při shodě s názvem souboru -- "ÈAS OPOVR\\x8eENÍ" zůstalo (7. 10.)."""
    from app.tools.rebuild_own_library import fix_text

    return fix_text(title, stem) or title


def tidy_tag(text: str | None, path: str, person: bool = False) -> str | None:
    """Oprava kódování + tag celý VELKÝMI písmeny na běžný zápis
    ("ANDRZEJ SAPKOWSKI" -> "Andrzej Sapkowski", "ČAS OPOVRŽENÍ" -> "Čas opovržení")."""
    if not text:
        return text
    text = fix_title_encoding(text, path)
    letters = [c for c in text if c.isalpha()]
    if len(letters) >= 4 and all(c.isupper() for c in letters):
        text = " ".join(w.capitalize() for w in text.lower().split(" ")) if person else text[:1] + text[1:].lower()
    return text


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
    # "._03.mp3" = skrytý doprovodný soubor z Macu (AppleDouble), ne kapitola.
    files = [p for p in root.rglob("*") if p.is_file() and p.suffix.lower() in AUDIO and not p.name.startswith("._")]
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


def _common_parts(dirs: list[Path]) -> tuple[str, ...]:
    parts = dirs[0].parts
    for d in dirs[1:]:
        n = 0
        while n < min(len(parts), len(d.parts)) and parts[n] == d.parts[n]:
            n += 1
        parts = parts[:n]
    return parts or ("/",)


def import_book(book_id: str, root: Path, only: list[Path] | None = None) -> int:
    """Vrátí počet souborů. Pořadí: složky (CD1, CD2…) přirozeně, uvnitř číslo
    stopy z tagu, jinak přirozené řazení jmen. `only`: jen tyhle soubory
    (kniha vybraná ze sbírky)."""
    if only is not None:
        files = [p for p in only if p.suffix.lower() in AUDIO and p.is_file()]
        if files:
            root = Path(*_common_parts([p.parent for p in files]))
    else:
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
        # Stejný soubor = stejný řádek (id): import běží i průběžně, jak
        # dorážejí další kapitoly, a uložená pozice (file_id) nesmí zmizet.
        existing = {
            f.path: f for f in session.exec(select(SpokenFile).where(SpokenFile.book_id == book_id)).all()
        }
        keep = {str(p) for p, _ in rows}
        for path, row in existing.items():
            if path not in keep:
                session.delete(row)
        # Všechny části se často jmenují jako kniha ("Saturnin", "Saturnin")
        # -- v seznamu kapitol by nešly rozlišit, pak radši "Část N".
        titles = [fix_title_encoding(_tag(audio, "title") or p.stem, p.stem) for p, audio in rows]
        if len(rows) > 1 and len(set(titles)) < len(titles):
            titles = [f"Část {i + 1}" for i in range(len(rows))]
        total = 0
        for i, (p, audio) in enumerate(rows):
            length = getattr(getattr(audio, "info", None), "length", None)
            duration = int(length * 1000) if length else None
            total += duration or 0
            row = existing.get(str(p)) or SpokenFile(book_id=book_id, position=i, path=str(p))
            row.position = i
            row.title = titles[i]
            row.duration_ms = duration
            row.chapters = _chapters(p)
            session.add(row)
        first = rows[0][1]
        # Album v tagu = název knihy (čistší než název vydání na trackeru).
        where = str(rows[0][0])
        album = tidy_tag(_tag(first, "album"), where)
        # Název z katalogu i ruční úprava (Upravit knihu) mají přednost před tagem.
        if album and len(album) <= 200 and book.metadata_source not in (CATALOG, "manual"):
            book.title = album
        book.author = book.author or tidy_tag(_tag(first, "albumartist", "artist"), where, person=True)
        book.narrator = book.narrator or tidy_tag(_tag(first, "performer", "composer"), where, person=True)
        book.duration_ms = total or None
        book.storage_dir = str(root)
        session.add(book)
        session.commit()
    return len(rows)


CATALOG = "audioknihy.cz"


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
