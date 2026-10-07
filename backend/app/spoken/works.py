"""Stránka knihy (audioknihy jako katalog, fáze 2): kniha z Knihovny.cz
a VŠECHNA její vydání -- ze SkTorrentu (jen ta, která k ní jistě patří,
`catalog.match_record`) i kopie, které už jsou na serveru. Nahoře
doporučené vydání s důvodem; nic se nepřiděluje, vybírá uživatel.
Návrh: opentify-notes/audioknihy-katalog-navrh-2026-10-07.md.
"""

from __future__ import annotations

import logging
import math
import re
from typing import Any

from sqlmodel import Session, select

from app.db import engine
from app.models import SpokenBook, SpokenProgress
from app.spoken import catalog, sktorrent
from app.spoken.acquire import book_out

logger = logging.getLogger(__name__)


def _surname(author: str) -> str:
    author = re.sub(r",?\s*\d{3,4}\s*-.*$", "", author or "").strip()
    if "," in author:
        return catalog.fold(author.split(",")[0])
    parts = catalog.fold(author).split()
    return parts[-1] if parts else ""


def same_work(record_a: dict[str, Any], title: str, author: str) -> bool:
    """Záznam knihovny je ta kniha: název (bez dílu řady) a příjmení autora."""
    return catalog.fold(title) in catalog._title_variants(record_a) and _surname(author) in catalog._primary_surnames(record_a)


async def find_work(title: str, author: str) -> tuple[dict[str, Any] | None, list[dict[str, Any]]]:
    """(dílo, všechny záznamy téhož díla -- vydání v knihovnách)."""
    records = await catalog._search(f"{title} {_surname(author)}", limit=40)
    same = [r for r in records if same_work(r, title, author)]
    if not same:
        return None, []
    # Popis: první záznam, který ho má (audio vydání často bez anotace).
    best = next((r for r in same if r.get("summary") and any(r["summary"])), same[0])
    work = catalog.work_out(best)
    # Rok = nejstarší vydání v knihovnách (ne poslední dotisk); řada z
    # kteréhokoli záznamu, který ji má ("Zaklínač. I., …").
    years = [int(m.group()) for r in same for d in r.get("publicationDates") or [] if (m := re.search(r"\d{4}", d))]
    work["year"] = str(min(years)) if years else work["year"]
    work["series"] = work["series"] or next((s for r in same if (s := catalog._series(r))), None)
    return work, same


def _sources(n: int) -> str:
    word = "zdroj" if n == 1 else ("zdroje" if 2 <= n <= 4 else "zdrojů")
    return f"{n} {word}"


# --- Doporučené vydání --------------------------------------------------------

def rank(edition: dict[str, Any], liked_narrators: set[str]) -> tuple[float, list[str]]:
    """(skóre, důvody). Pořadí z návrhu: celé > část, nezkrácené, četba před
    dramatizací, čeština, interpret, kterého posloucháš, víc zdrojů."""
    score, why = 0.0, []
    if edition.get("bookId") and edition.get("status") == "ready":
        score += 60
        why.append("na serveru, pustíš hned")
    if edition.get("cdPart"):
        score -= 80
        why.append("jen část (CD)")
    else:
        score += 40
        why.append("celé")
    if edition.get("abridged"):
        score -= 30
        why.append("zkrácené")
    elif not edition.get("cdPart"):
        why.append("nezkrácené")
    if edition.get("drama"):
        score -= 15
        why.append("dramatizace")
    if edition.get("lang") in (None, "cs"):
        score += 10
    elif edition.get("lang") == "sk":
        why.append("slovensky")
    narrator = edition.get("narrator")
    if narrator:
        if catalog.fold(narrator) in liked_narrators:
            score += 20
            why.append(f"čte {narrator} (posloucháš)")
        else:
            why.append(f"čte {narrator}")
    seeders = int(edition.get("seeders") or 0)
    if not edition.get("bookId"):
        score += 8 * math.log1p(seeders)
        why.append(_sources(seeders) if seeders else "teď nikdo nesdílí")
        if seeders == 0:
            score -= 40
    return score, why


def _liked_narrators(user_id: str) -> set[str]:
    with Session(engine) as session:
        ids = [p.book_id for p in session.exec(select(SpokenProgress).where(SpokenProgress.user_id == user_id)).all()]
        books = session.exec(select(SpokenBook).where(SpokenBook.id.in_(ids))).all() if ids else []  # type: ignore[attr-defined]
    return {catalog.fold(b.narrator) for b in books if b.narrator}


async def work_page(title: str, author: str, user_id: str) -> dict[str, Any] | None:
    work, records = await find_work(title, author)
    if work is None:
        return None
    editions: list[dict[str, Any]] = []
    # Kopie na serveru (stejný název a autor).
    want_surname = _surname(work["author"] or "")

    def is_this_work(b: SpokenBook) -> bool:
        # Stejné párování jako u vydání ze SkTorrentu; u knihy s názvem
        # z katalogu (audioknihy.cz) stačí název + autor.
        if catalog.match_record(catalog.parse_release(b.release_title or ""), records) is not None:
            return True
        return bool(b.author) and catalog.fold(b.title) == catalog.fold(work["title"]) and want_surname in catalog.fold(b.author).split()

    with Session(engine) as session:
        on_server = [b for b in session.exec(select(SpokenBook).where(SpokenBook.status != "failed")).all() if is_this_work(b)]
    known_refs = {b.source_ref for b in on_server}
    for b in on_server:
        parsed = catalog.parse_release(b.release_title or b.title)
        editions.append({
            **book_out(b), "bookId": b.id, "source": b.source, "narrator": b.narrator or parsed["narrator"],
            "lang": parsed["lang"], "cdPart": parsed["cdPart"], "abridged": parsed["abridged"], "drama": parsed["drama"],
        })
    # Vydání ze SkTorrentu, která k té knize jistě patří.
    try:
        releases = await sktorrent.search(f"{work['title']} {_surname(work['author'] or '')}")
    except Exception:  # noqa: BLE001 - SkTorrent nedostupný: stránka i tak ukáže knihu a kopie na serveru
        releases = []
    for r in releases:
        if r.infohash in known_refs:
            continue
        parsed = catalog.parse_release(r.title)
        if parsed["collection"] or catalog.match_record(parsed, records) is None:
            continue
        editions.append({
            **r.to_json(), "source": "sktorrent", "narrator": parsed["narrator"], "year": (parsed["years"] or [None])[0],
            "durationMin": parsed["durationMin"], "lang": parsed["lang"], "cdPart": parsed["cdPart"],
            "abridged": parsed["abridged"], "drama": parsed["drama"],
        })
    liked = _liked_narrators(user_id)
    for e in editions:
        e["score"], e["why"] = rank(e, liked)
    editions.sort(key=lambda e: -e["score"])
    return {"work": work, "editions": editions, "recommended": editions[0] if editions else None}
