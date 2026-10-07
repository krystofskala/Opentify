"""Vlastní audioknihy (ze složek, ne ze SkTorrentu / Soulseeku) do Opentify.

Každá podsložka `zdroj` se zvukem = jedna kniha. Složka se PŘESUNE do
složky audioknih (`SPOKEN_ROOT/local-…`), takže `zdroj` má být kopie
(originál na houbaři zůstane netknutý -- zkopírovat na hostiteli předem do
`<SPOKEN_DIR>/_import/`). Název knihy = jméno složky; autor a čistý název se
doplní samy z katalogu (worker, `acquire` metadata backfill). Stejná složka
dvakrát se nepřidá (source_ref podle jména a velikosti).

    docker compose exec -T worker python -m app.tools.import_local_books /data/spoken/_import
"""

from __future__ import annotations

import hashlib
import shutil
import sys
from pathlib import Path

from sqlmodel import Session, select

from app.auth import ADMIN_ID
from app.db import engine
from app.models import SpokenBook
from app.spoken.acquire import SPOKEN_ROOT
from app.spoken.importer import audio_files, import_book
from app.utils import utcnow


def _ref(folder: Path) -> str:
    size = sum(p.stat().st_size for p in audio_files(folder))
    return "local:" + hashlib.sha1(f"{folder.name}\n{size}".encode()).hexdigest()


def books_in(source: Path) -> list[Path]:
    """Složky se zvukem (přímo `source`, když zvuk obsahuje sám)."""
    if audio_files(source) and not any(p.is_dir() and audio_files(p) for p in source.iterdir()):
        return [source]
    return sorted(p for p in source.iterdir() if p.is_dir() and audio_files(p))


def import_folder(folder: Path, user_id: str = ADMIN_ID) -> tuple[str, int] | None:
    """(id knihy, počet souborů), nebo None, když už je v knihovně."""
    ref = _ref(folder)
    with Session(engine) as session:
        if session.exec(select(SpokenBook).where(SpokenBook.source_ref == ref)).first() is not None:
            return None
    dest = SPOKEN_ROOT / f"local-{ref.split(':')[1][:16]}"
    if folder.resolve() != dest.resolve():
        shutil.move(str(folder), str(dest))
    book = SpokenBook(
        source="local", source_ref=ref, release_title=folder.name, title=folder.name,
        status="importing", progress=1.0, storage_dir=str(dest), requested_by_user_id=user_id,
    )
    with Session(engine) as session:
        session.add(book)
        session.commit()
        book_id = book.id
    count = import_book(book_id, dest)
    with Session(engine) as session:
        row = session.get(SpokenBook, book_id)
        if row is not None:
            row.status = "ready"
            row.finished_at = utcnow()
            session.add(row)
            session.commit()
    return book_id, count


def main() -> None:
    if len(sys.argv) < 2:
        raise SystemExit(__doc__)
    source = Path(sys.argv[1])
    for folder in books_in(source):
        out = import_folder(folder)
        print(f"{folder.name}: " + ("už v knihovně" if out is None else f"přidáno ({out[1]} souborů, {out[0]})"))


if __name__ == "__main__":
    main()
