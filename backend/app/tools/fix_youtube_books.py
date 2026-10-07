"""Doplní už stažené knihy z YouTube (název kapitoly, obal, popis, kapitoly).

    docker compose exec -T worker python -m app.tools.fix_youtube_books
"""

from __future__ import annotations

import asyncio
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.models import SpokenBook
from app.spoken import youtube
from app.spoken.acquire import SPOKEN_ROOT, youtube_finish


async def main() -> None:
    with Session(engine) as session:
        books = [(b.id, (b.source_files or {}).get("video"), b.storage_dir) for b in session.exec(
            select(SpokenBook).where(SpokenBook.source == "youtube", SpokenBook.status == "ready")
        ).all()]
    for book_id, vid, storage in books:
        meta = await youtube.info(vid) if vid else None
        if meta is None:
            print(f"{book_id[:8]}: video nenačteno")
            continue
        await asyncio.to_thread(youtube_finish, book_id, Path(storage or SPOKEN_ROOT / book_id), meta)
        print(f"{book_id[:8]}: {meta['title']} doplněno")


if __name__ == "__main__":
    asyncio.run(main())
