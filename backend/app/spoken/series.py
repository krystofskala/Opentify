"""Řady a pořadí čtení (audioknihy jako katalog, fáze 3) -- automaticky
z Wikidat (běžné API, ne SPARQL), bez ručních seznamů (uživatel 8. 10.: "knižní série musíme
automaticky, ne ručně každou").

Kniha (název + autor) -> dílo na Wikidatech (P179 = řada, P50 = autor)
-> všechna díla řady s číslem dílu (kvalifikátor P1545). Bere se jen dílo
s autorem a ne povídka -- filmy ("Harry Potter a Kámen mudrců", 2001)
autora nemají, povídky Zaklínače by pořadí zahltily. Díl bez čísla, který
přesně zapadne do mezery v číslování podle roku vydání (Paní jezera mezi
6 a 8), dostane chybějící číslo; ostatní jsou "Mimo pořadí".
"""

from __future__ import annotations

import logging
import re
from typing import Any

from sqlmodel import Session, select

from app.catalog.cache import cached_json
from app.db import engine
from app.models import SpokenBook, SpokenProgress
from app.spoken.catalog import fold
from app.spoken.people import _wd

logger = logging.getLogger(__name__)

TTL_S = 30 * 24 * 3600
_SHORT_STORY = "Q49084"


def _surname(author: str) -> str:
    author = re.sub(r",?\s*\d{3,4}\s*-.*$", "", author or "").strip()
    if "," in author:
        return fold(author.split(",")[0])
    parts = fold(author).split()
    return parts[-1] if parts else ""


def _label(entity: dict[str, Any]) -> str | None:
    labels = entity.get("labels") or {}
    return next((labels[lang]["value"] for lang in ("cs", "sk", "en") if lang in labels), None)


def _ids(entity: dict[str, Any], prop: str) -> list[str]:
    out = []
    for c in (entity.get("claims") or {}).get(prop) or []:
        value = ((c.get("mainsnak") or {}).get("datavalue") or {}).get("value")
        if isinstance(value, dict) and value.get("id"):
            out.append(value["id"])
    return out


async def _find_series(title: str, author: str) -> tuple[str, str] | None:
    """(id řady, id díla) pro knihu -- jen dílo se stejným názvem a autorem."""
    hits = (await _wd({"action": "wbsearchentities", "search": title, "language": "cs", "uselang": "cs",
                       "limit": 10, "type": "item"})).get("search") or []
    if not hits:
        return None
    entities = (await _wd({"action": "wbgetentities", "ids": "|".join(h["id"] for h in hits),
                           "props": "claims|labels|aliases", "languages": "cs|sk|en"})).get("entities") or {}
    candidates = [
        (qid, e) for qid, e in entities.items()
        if _ids(e, "P179") and _ids(e, "P50") and fold(title) in {
            fold(v["value"]) for v in [*(e.get("labels") or {}).values(), *[a for al in (e.get("aliases") or {}).values() for a in al]]
        }
    ]
    if not candidates:
        return None
    author_ids = sorted({a for _, e in candidates for a in _ids(e, "P50")})
    people = (await _wd({"action": "wbgetentities", "ids": "|".join(author_ids[:50]), "props": "labels",
                         "languages": "cs|sk|en"})).get("entities") or {}
    want = _surname(author)
    for qid, e in candidates:
        names = {fold(v["value"]) for a in _ids(e, "P50") for v in ((people.get(a) or {}).get("labels") or {}).values()}
        if want and any(want in n.split() for n in names):
            return _ids(e, "P179")[0], qid
    return None


def _number(text: str | None) -> float | None:
    try:
        return float(str(text).replace(",", "."))
    except (TypeError, ValueError):
        return None


def _series_rows(entities: dict[str, Any], series_id: str) -> list[dict[str, Any]]:
    """Díla řady z entit Wikidat: jen s autorem (P50), s číslem dílu
    (kvalifikátor P1545 u P179), rokem (P577) a druhem (P31)."""
    rows = []
    for qid, e in entities.items():
        if not _ids(e, "P50"):
            continue  # film, hra, seriál -- kniha má autora
        number = None
        for c in (e.get("claims") or {}).get("P179") or []:
            value = ((c.get("mainsnak") or {}).get("datavalue") or {}).get("value") or {}
            if value.get("id") != series_id:
                continue
            for q in (c.get("qualifiers") or {}).get("P1545") or []:
                n = _number(((q.get("datavalue") or {}).get("value")))
                if n is not None:
                    number = n if number is None else min(number, n)
        years = []
        for c in (e.get("claims") or {}).get("P577") or []:
            t = (((c.get("mainsnak") or {}).get("datavalue") or {}).get("value") or {}).get("time") or ""
            if m := re.match(r"[+-]?(\d{4})", t):
                years.append(int(m.group(1)))
        rows.append({"qid": qid, "title": _label(e) or qid, "number": number,
                     "year": min(years) if years else None, "kinds": set(_ids(e, "P31"))})
    return rows


def order_parts(works: list[dict[str, Any]]) -> tuple[list[dict[str, Any]], list[dict[str, Any]]]:
    """(díly v pořadí, mimo pořadí). Povídky ven; díl bez čísla, který podle
    roku zapadne do jediné mezery, ji vyplní."""
    items = [dict(w) for w in works if not re.fullmatch(r"Q\d+", w["title"]) and _SHORT_STORY not in w["kinds"]]
    numbered = sorted((w for w in items if w["number"] is not None), key=lambda w: w["number"])
    # Jiné vydání téhož dílu (stejný název) mimo pořadí neopakovat a mezeru jím nevyplňovat.
    titles = {fold(w["title"]) for w in numbered}
    loose = [w for w in items if w["number"] is None and fold(w["title"]) not in titles]
    taken = {int(w["number"]) for w in numbered if float(w["number"]).is_integer()}
    if taken:
        for gap in range(1, max(taken)):
            if gap in taken:
                continue
            before = next((w for w in reversed(numbered) if w["number"] < gap), None)
            after = next((w for w in numbered if w["number"] > gap), None)
            lo = before["year"] if before and before["year"] else None
            hi = after["year"] if after and after["year"] else None
            fits = [w for w in loose if w["year"] and (lo is None or w["year"] >= lo) and (hi is None or w["year"] <= hi)]
            if len(fits) == 1:
                fits[0]["number"] = float(gap)
                loose.remove(fits[0])
                numbered.append(fits[0])
                numbered.sort(key=lambda w: w["number"])
    loose.sort(key=lambda w: (w["year"] or 9999, w["title"]))

    def out(w: dict[str, Any]) -> dict[str, Any]:
        n = w["number"]
        return {"qid": w["qid"], "title": w["title"], "year": w["year"],
                "number": (int(n) if n is not None and float(n).is_integer() else n)}

    return [out(w) for w in numbered], [out(w) for w in loose]


async def _series_entities(series_id: str) -> dict[str, Any]:
    """Všechna díla s P179 = řada (vyhledávání haswbstatement, ne SPARQL --
    WDQS při výpadku pouští 1 dotaz za minutu, 8. 10.)."""
    hits = (await _wd({"action": "query", "list": "search", "srsearch": f"haswbstatement:P179={series_id}",
                       "srlimit": 200, "srnamespace": 0})).get("query", {}).get("search") or []
    ids = [h["title"] for h in hits if re.fullmatch(r"Q\d+", h.get("title") or "")]
    entities: dict[str, Any] = {}
    for i in range(0, min(len(ids), 150), 50):
        batch = (await _wd({"action": "wbgetentities", "ids": "|".join(ids[i:i + 50]), "props": "claims|labels",
                            "languages": "cs|sk|en"})).get("entities") or {}
        entities.update(batch)
    return entities


def common_prefix(titles: list[str]) -> str:
    """Záloha za název řady: společný začátek názvů dílů ("Harry Potter")."""
    if len(titles) < 2:
        return ""
    words = [t.split() for t in titles]
    out = []
    for group in zip(*words):
        if len({fold(w) for w in group}) != 1:
            break
        out.append(group[0])
    while out and len(out[-1]) <= 2:  # "Harry Potter a" -> "Harry Potter"
        out.pop()
    return " ".join(out).strip(" -–:,.")


async def lookup(title: str, author: str) -> dict[str, Any] | None:
    """Řada knihy s díly (30 dní v mezipaměti, i "není" -- jako prázdné)."""

    async def build() -> dict[str, Any]:
        found = await _find_series(title, author)
        if found is None:
            return {}
        series_id, work_id = found
        parts, loose = order_parts(_series_rows(await _series_entities(series_id), series_id))
        if len(parts) + len(loose) < 2:
            return {}
        name = _label(((await _wd({"action": "wbgetentities", "ids": series_id, "props": "labels",
                                   "languages": "cs|sk|en"})).get("entities") or {}).get(series_id) or {})
        return {"id": series_id, "name": name or common_prefix([w["title"] for w in parts]), "workId": work_id, "author": author, "parts": parts, "loose": loose}

    data = await cached_json(f"spoken:series:v1:{fold(title)}|{_surname(author)}", TTL_S, build, is_empty=lambda d: False)
    return data or None


def with_library(series: dict[str, Any], user_id: str) -> dict[str, Any]:
    """U každého dílu, co je na serveru a jak daleko jsi (dočteno /
    rozposloucháno) -- podle názvu a příjmení autora."""
    want = _surname(series.get("author") or "")
    with Session(engine) as session:
        books = [b for b in session.exec(select(SpokenBook).where(SpokenBook.status != "failed")).all()
                 if b.author and want and want in fold(b.author).split()]
        progress = {p.book_id: p for p in session.exec(select(SpokenProgress).where(SpokenProgress.user_id == user_id)).all()}

    def same_title(book_title: str, title: str) -> bool:
        # "Zaklínač I - Poslední přání" je díl "Poslední přání"; krátký název
        # ("Mort") jen přesně.
        b = fold(book_title)
        return b == title or (len(title) >= 8 and (b.endswith(f" {title}") or f" {title} " in f" {b} "))

    def attach(part: dict[str, Any]) -> dict[str, Any]:
        title = fold(part["title"])
        same = [b for b in books if same_title(b.title, title)]
        if not same:
            return {**part, "bookId": None, "state": None}
        # Rozposlouchaná / dočtená kopie má přednost, pak hotová.
        same.sort(key=lambda b: (b.id not in progress, b.status != "ready"))
        b = same[0]
        p = progress.get(b.id)
        state = "finished" if p and p.finished else "listening" if p else "ready" if b.status == "ready" else "downloading"
        return {**part, "bookId": b.id, "state": state}

    return {**series, "parts": [attach(p) for p in series["parts"]], "loose": [attach(p) for p in series["loose"]]}
