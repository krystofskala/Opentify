"""Knihy na serveru -> řada a díl (Wikidata, `spoken/series.py`) a u dílů
z kompletu vlastní obal (uživatel 8. 10.: "když stáhnu sérii, mají často
všechny jeden obrázek").

Běží ve workeru po kouscích (`tick`, 2 knihy za kolo): z názvu knihy
("kniha 1.poslední přání", "Zaklinac I - Posledni prani", "01 - Krev elfu")
se zkusí názvy dílu, ke každému řada autora; díl řady se stejným názvem =
shoda. Pak:
  - `series_name` / `series_number` (v knihovně "díl 3"),
  - název s diakritikou z Wikidat, když byl jen bez ní ("posledni prani"),
  - vlastní obal z Google Books (české vydání, stejný název a autor), když
    kniha obal nemá nebo ho sdílí s jinými knihami (komplet).
Nic se nemaže; knihu bez řady označí "" a už ji nezkouší.
"""

from __future__ import annotations

import asyncio
import logging
import re

from sqlmodel import Session, func, select

from app.db import engine
from app.models import SpokenBook
from app.spoken import series
from app.spoken.catalog import fold

logger = logging.getLogger(__name__)

_LEAD = re.compile(r"^\s*(?:(?:kniha|díl|dil|part|book|cd|cast|část)\s*)?\d{1,3}\s*[.):\-–]*\s*", re.I)
_ROMAN_LEAD = re.compile(r"^\s*[IVX]{1,4}\s*[.):\-–]+\s*")


def title_candidates(title: str) -> list[str]:
    """Možné názvy dílu z názvu knihy / složky, nejpravděpodobnější první."""
    t = re.sub(r"[\[(].*?[\])]", " ", title or "")
    t = " ".join(t.split())
    out: list[str] = []

    def add(x: str) -> None:
        x = _ROMAN_LEAD.sub("", _LEAD.sub("", x)).strip(" -–:.,")
        if len(x) >= 3 and fold(x) not in {fold(o) for o in out}:
            out.append(x)

    parts = [p for p in re.split(r"\s+[-–]\s+|:\s+", t) if p.strip()]
    # "Zaklinac I - Posledni prani": název dílu bývá za pomlčkou.
    for p in reversed(parts):
        add(p)
    add(t)
    return out[:3]


def _matching_part(found: dict, candidate: str) -> dict | None:
    want = fold(candidate)
    return next((p for p in found["parts"] if fold(p["title"]) == want), None)


def _shared_cover(book: SpokenBook) -> bool:
    if not book.cover_url:
        return True
    with Session(engine) as session:
        n = session.exec(select(func.count()).select_from(SpokenBook).where(SpokenBook.cover_url == book.cover_url)).one()
    return n > 1


async def link(book: SpokenBook) -> dict:
    """Řada a díl jedné knihy -> pole k uložení (vyhazuje při 429)."""
    for cand in title_candidates(book.title):
        found = await series.lookup(cand, book.author or "")
        if not found:
            continue
        part = _matching_part(found, cand)
        if part is None:
            continue
        fields: dict = {"series_name": found["name"] or "Řada", "series_number": part["number"]}
        # "kniha 1.posledni prani" -> "Poslední přání" (název z katalogu
        # audioknihy.cz se nepřepisuje).
        if book.metadata_source != "audioknihy.cz" and book.title != part["title"]:
            fields["title"] = part["title"]
        if _shared_cover(book):
            from app.spoken.acquire import SPOKEN_ROOT
            from app.spoken.describe import cover_image

            dest = SPOKEN_ROOT / "covers" / f"{book.id}.jpg"
            if await cover_image(part["title"], book.author or "", dest):
                fields["cover_url"] = f"spoken/books/{book.id}/cover"
        return fields
    return {"series_name": ""}


async def tick(r, limit: int = 2) -> None:
    if await r.get("spoken:series:backoff"):
        return

    def todo() -> list[SpokenBook]:
        with Session(engine) as session:
            books = list(session.exec(
                select(SpokenBook).where(
                    SpokenBook.status == "ready",
                    SpokenBook.author.is_not(None),  # type: ignore[union-attr]
                    SpokenBook.series_name.is_(None),  # type: ignore[union-attr]
                ).limit(limit)
            ).all())
            for b in books:
                session.expunge(b)
            return books

    from app.spoken.acquire import _save

    for book in await asyncio.to_thread(todo):
        try:
            fields = await link(book)
        except Exception as e:  # noqa: BLE001 -- 429 / výpadek: 15 min pauza, nic se neuloží
            logger.info("řada knihy %s: %s", book.id, e)
            await r.set("spoken:series:backoff", "1", ex=900)
            return
        if fields.get("series_name"):
            logger.info("kniha %r: %s, díl %s", book.title, fields["series_name"], fields.get("series_number"))
        await _save(book.id, **fields)

