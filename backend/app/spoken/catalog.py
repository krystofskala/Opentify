"""Audioknihy jako katalog (fáze 1): rozbor názvu vydání ze SkTorrentu
a jisté spárování na knihu (dílo) přes Knihovny.cz -- celostátní portál
českých knihoven (otevřené API, bez klíče). Návrh:
opentify-notes/audioknihy-katalog-navrh-2026-10-07.md.

Párování jen určuje, KE KTERÉ KNIZE vydání patří (ke knize jich může patřit
víc -- různí interpreti, roky, formáty). Při pochybnosti nic: nespárované
vydání zůstane "nezařazené", nikdy se neschová.

Jistá shoda = název knihy (bez diakritiky, bez čísla dílu řady) se rovná
jedné straně názvu vydání a příjmení hlavního autora je v druhé straně.
Pořadí "Autor - Název" / "Název - Autor" se nezkoumá, zkusí se obě.
"""

from __future__ import annotations

import asyncio
import logging
import re
import time
import unicodedata
from typing import Any

import httpx

logger = logging.getLogger(__name__)

SEARCH_URL = "https://www.knihovny.cz/api/v1/search"
_FIELDS = [
    "id", "title", "shortTitle", "titleSection", "authors", "formats", "publicationDates",
    "series", "physicalDescriptions", "summary", "languages",
]
_http = httpx.AsyncClient(timeout=20.0, headers={"User-Agent": "Opentify/0.1 (self-hosted audiobook catalog)"})
_GAP_S = 0.5
_lock = asyncio.Lock()
_last = 0.0


# Písmena, která se rozkladem NFKD nerozloží ("Nesbø" -> "nesb", polské ł).
_SPECIAL = str.maketrans({"ø": "o", "Ø": "O", "ł": "l", "Ł": "L", "æ": "ae", "Æ": "AE", "ß": "ss", "đ": "d", "Đ": "D", "þ": "th", "œ": "oe"})


def fold(text: str | None) -> str:
    text = unicodedata.normalize("NFKD", (text or "").translate(_SPECIAL)).encode("ascii", "ignore").decode().casefold()
    text = re.sub(r"[^a-z0-9]+", " ", text)
    return " ".join(text.split())


# --- Rozbor názvu vydání -----------------------------------------------------

_YEAR = re.compile(r"(?<!\d)(19\d\d|20\d\d)(?!\d)")
_DURATION = re.compile(r"(\d{1,3})\s*h\s*(\d{1,2})?\s*m?", re.I)
_LANG = re.compile(r"\b(cz|cs|sk|en|eng)\b", re.I)
_NARRATOR = re.compile(r"\b(?:čte|cte|čtou|ctou|účinkují|ucinkuji)\s*:?\s+([^()\[\]]+)", re.I)
_COLLECTION = re.compile(
    # "Série: Harry Hole 13." je jedna kniha z řady -- sbírka je "serie
    # Zaklinac (2013-2017)", tedy série s rozsahem let (níž `_YEAR_RANGE`).
    r"\b(komplet\w*|sbirk\w*|sbírk\w*|trilogie|tetralogie|pentalogie|collection|zbierk\w*|\d+\s*kn\w*h|vsechny|všechny)\b",
    re.I,
)
_YEAR_RANGE = re.compile(r"(?:19|20)\d\d\s*[-–]\s*(?:19|20)\d\d")
_ABRIDGED = re.compile(r"\b(zkr[aá]cen\w*|kr[aá]ceno|abridged)\b", re.I)
_DRAMA = re.compile(r"\b(rozhlasov\w*|dramatizac\w*|rozhlasova hra|rozhlasová hra|hra)\b", re.I)
# Šum na začátku: "55-", "01 ", "(UZ16)", "Série: Harry Hole 13. -"
_LEAD_NOISE = re.compile(r"^\s*(?:\d{1,3}\s*[-.)]\s*|\d{1,3}\s+)")
_TAGS = re.compile(r"\((?:UZ|ZE|HH)?\d+\)|\[[^\]]*\]", re.I)


def parse_release(title: str) -> dict[str, Any]:
    """Co se dá z názvu vydání vyčíst: dvě strany (autor / název v neznámém
    pořadí), rok, interpret, délka, jazyk a příznaky (sbírka, část CD,
    zkráceno, dramatizace)."""
    raw = title or ""
    years = [int(y) for y in _YEAR.findall(raw)]
    narrator = None
    m = _NARRATOR.search(raw)
    if m:
        narrator = m.group(1).strip(" -,.")
    lang = None
    lm = _LANG.search(raw)
    if lm:
        lang = {"cz": "cs", "cs": "cs", "sk": "sk", "en": "en", "eng": "en"}[lm.group(1).lower()]
    duration_min = None
    dm = _DURATION.search(raw)
    if dm and re.search(r"\d\s*h\s*\d*\s*m", raw, re.I):
        duration_min = int(dm.group(1)) * 60 + int(dm.group(2) or 0)
    # Interpret v závorce bez "čte": "(David Matasek)2019(8h22m)" -- jméno
    # o 2-3 slovech s velkými písmeny, ne jazyk/rok/délka.
    if narrator is None:
        for inner in re.findall(r"\(([^()]+)\)", raw):
            words = inner.strip().split()
            if 2 <= len(words) <= 4 and all(w[:1].isupper() for w in words if w[:1].isalpha()) and not _YEAR.search(inner) \
                    and not _LANG.fullmatch(inner.strip()) and not re.search(r"\d", inner) and "&" not in inner:
                narrator = inner.strip()
                break
    # Hlavní text: bez závorek, štítků a koncového šumu.
    main = _TAGS.sub(" ", raw)
    main = re.sub(r"\([^()]*\)", " ", main)
    main = re.sub(r"\b(?:čte|cte)\b.*$", " ", main, flags=re.I)
    main = re.sub(r"=\s*\d+\s*%", " ", main)
    main = re.sub(r"[´`]", " ", main)
    main = _YEAR.sub(" ", main)
    # "20CD", "20. CD", "Disc 3" do názvu knihy nepatří (část je v `cdPart`).
    main = re.sub(r"\b\d+\s*\.?\s*cd\b|\bcd\s*\d+\b|\bdisc\s*\d+\b", " ", main, flags=re.I)
    main = re.sub(r"\s+", " ", main).strip(" -–,.")
    parts = [p.strip(" -–,.") for p in re.split(r"\s+[-–]\s+|\s*/\s*|:\s+|\s+-(?=\S)|(?<=\S)-\s+", main) if p.strip(" -–,.")]
    parts = [_LEAD_NOISE.sub("", p).strip() for p in parts]
    parts = [p for p in parts if p]
    return {
        "parts": parts,
        "years": years,
        "narrator": narrator,
        "lang": lang,
        "durationMin": duration_min,
        "collection": bool(_COLLECTION.search(raw)) or bool(_YEAR_RANGE.search(raw)),
        # "20. CD" / "Disc 3" = jedna část; "20CD" / "3CD" = celé vydání na discích.
        "cdPart": bool(re.search(r"\b\d+\s*\.\s*cd\b|\bcd\s*\d+\b|\bdisc\s*\d+\b", raw, re.I)),
        "abridged": bool(_ABRIDGED.search(raw)),
        "drama": bool(_DRAMA.search(raw)),
    }


# --- Knihovny.cz -------------------------------------------------------------

async def _search(lookfor: str, limit: int = 20) -> list[dict[str, Any]]:
    global _last
    async with _lock:
        wait = _GAP_S - (time.monotonic() - _last)
        if wait > 0:
            await asyncio.sleep(wait)
        try:
            resp = await _http.get(
                SEARCH_URL, params={"lookfor": lookfor, "type": "AllFields", "limit": limit, "field[]": _FIELDS}
            )
        finally:
            _last = time.monotonic()
    resp.raise_for_status()
    return resp.json().get("records") or []


def _primary_surnames(record: dict[str, Any]) -> list[str]:
    """"Andrzej Sapkowski, 1948-" -> "sapkowski"; "Hašek, Jaroslav" -> "hasek"."""
    out = []
    primary = (record.get("authors") or {}).get("primary") or {}
    for name in primary if isinstance(primary, dict) else []:
        name = re.sub(r",?\s*\d{3,4}\s*-\s*(\d{3,4})?\s*$", "", name).strip()
        if "," in name:
            surname = name.split(",")[0]
        else:
            surname = name.split()[-1] if name.split() else ""
        if fold(surname):
            out.append(fold(surname).split()[-1])
    return out


def _secondary_names(record: dict[str, Any]) -> list[str]:
    secondary = (record.get("authors") or {}).get("secondary") or {}
    return [re.sub(r",?\s*\d{3,4}\s*-.*$", "", n).strip() for n in secondary] if isinstance(secondary, dict) else []


_SERIES_PREFIX = re.compile(r"^(.*?)\.\s*(?:[IVXLC]+|\d+)\s*\.?,?\s*(.+)$")


def _title_variants(record: dict[str, Any]) -> set[str]:
    """Název knihy bez čísla dílu řady: "Zaklínač. I., Poslední přání" ->
    "posledni prani" (i celý "zaklinac posledni prani"); podtitul pryč."""
    out: set[str] = set()
    for t in (record.get("title"), record.get("shortTitle")):
        if not t:
            continue
        t = re.split(r"\s+:\s+|\s+/\s*", t)[0]
        out.add(fold(t))
        m = _SERIES_PREFIX.match(t)
        if m:
            out.add(fold(m.group(2)))
            out.add(fold(f"{m.group(1)} {m.group(2)}"))
    section = record.get("titleSection")
    if section:
        section = re.sub(r"^\s*(?:[IVXLC]+|\d+)\s*\.?,?\s*", "", section).strip(" /")
        if section:
            out.add(fold(section))
    return {t for t in out if t}


def _series(record: dict[str, Any]) -> dict[str, Any] | None:
    """{"name": "Zaklínač", "number": 1} z "Zaklínač. I., Poslední přání"."""
    t = record.get("title") or ""
    m = re.match(r"^(.*?)\.\s*([IVXLC]+|\d+)\s*\.?,?\s*\S", t)
    if not m:
        return None
    num = m.group(2)
    if num.isdigit():
        n = int(num)
    else:
        roman = {"I": 1, "V": 5, "X": 10, "L": 50, "C": 100}
        n, prev = 0, 0
        for ch in reversed(num):
            v = roman[ch]
            n = n - v if v < prev else n + v
            prev = max(prev, v)
    return {"name": m.group(1).strip(), "number": n}


def match_record(parsed: dict[str, Any], records: list[dict[str, Any]]) -> dict[str, Any] | None:
    """První záznam, jehož název se rovná jedné straně názvu vydání a jehož
    příjmení autora je v jiné straně (nebo kdekoli, když je strana jen jedna
    a autor je v ní na začátku/konci)."""
    parts = [fold(p) for p in parsed["parts"]]
    if not parts:
        return None
    whole = " ".join(parts)
    for record in records:
        titles = _title_variants(record)
        surnames = _primary_surnames(record)
        if not titles or not surnames:
            continue
        for i, part in enumerate(parts):
            if part not in titles:
                continue
            others = " ".join(p for j, p in enumerate(parts) if j != i)
            if any(s in others.split() for s in surnames):
                return record
        # "Zaklinac I Posledni prani" (název řady a dílu bez autora) + autor jinde
        for title in titles:
            if len(title.split()) >= 2 and f" {title} " in f" {whole} ":
                rest = f" {whole} ".replace(f" {title} ", " ")
                if any(s in rest.split() for s in surnames):
                    return record
    return None


def work_out(record: dict[str, Any]) -> dict[str, Any]:
    t = record.get("title") or ""
    m = _SERIES_PREFIX.match(re.split(r"\s+:\s+|\s+/\s*", t)[0])
    primary = (record.get("authors") or {}).get("primary") or {}
    return {
        "id": record.get("id"),
        "title": m.group(2) if m else re.split(r"\s+:\s+|\s+/\s*", t)[0],
        "author": next((re.sub(r",?\s*\d{3,4}\s*-.*$", "", n).strip() for n in primary), None) if isinstance(primary, dict) else None,
        "series": _series(record),
        "year": next(iter(record.get("publicationDates") or []), None),
        "audio": any("AUDIO" in f for f in record.get("formats") or []),
        "contributors": _secondary_names(record),
        "summary": next((s for s in record.get("summary") or [] if s), None),
    }


async def match_release(title: str) -> dict[str, Any] | None:
    """Kniha pro vydání, nebo None. Dotaz = všechna slova obou stran."""
    parsed = parse_release(title)
    if parsed["collection"] or not parsed["parts"]:
        return None  # sbírka není jedna kniha (fáze 2: rozpis obsahu)
    lookfor = " ".join(parsed["parts"])[:200]
    records = await _search(lookfor)
    record = match_record(parsed, records)
    return work_out(record) if record else None
