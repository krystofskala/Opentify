"""Oprava už stažených audioknih s rozbitou češtinou v názvech ("ÈAS
OPOVR\\x8eENÍ", "VÌ\\x8e VLA\\x8aTOVKY") a s tagy VELKÝMI písmeny -- stejná
oprava jako při importu (`importer.tidy_tag`). Mění jen to, co se opravdu
změní; vypíše co.

    docker compose exec -T worker python -m app.tools.fix_spoken_encoding
"""

from __future__ import annotations

from sqlmodel import Session, select

from app.db import engine
from app.models import SpokenBook, SpokenFile
from app.spoken.importer import CATALOG, fix_title_encoding, tidy_tag


def main() -> None:
    changed = 0
    with Session(engine) as session:
        for book in session.exec(select(SpokenBook)).all():
            where = book.storage_dir or book.release_title or ""
            new = {
                "title": book.title if book.metadata_source == CATALOG else tidy_tag(book.title, where),
                "author": tidy_tag(book.author, where, person=True),
                "narrator": tidy_tag(book.narrator, where, person=True),
            }
            diff = {k: v for k, v in new.items() if v != getattr(book, k)}
            if diff:
                print(f"{book.id[:8]}: " + ", ".join(f"{k}: {getattr(book, k)!r} -> {v!r}" for k, v in diff.items()))
                for k, v in diff.items():
                    setattr(book, k, v)
                session.add(book)
                changed += 1
            for f in session.exec(select(SpokenFile).where(SpokenFile.book_id == book.id)).all():
                fixed = fix_title_encoding(f.title, f.path) if f.title else f.title
                if fixed != f.title:
                    f.title = fixed
                    session.add(f)
        session.commit()
    print(f"opraveno knih: {changed}")


if __name__ == "__main__":
    main()
