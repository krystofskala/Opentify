"""Google Takeout z YouTube / YouTube Music.

- Historie poslechů: `watch-history.json` (nebo česky `historie
  sledování.json`), případně stejná historie jako HTML (výchozí formát
  Takeoutu -- česky i anglicky). Bere se jen YouTube Music, ne obyčejná
  videa. Takeout neříká, jak dlouho skladba hrála -> `ASSUMED_MS`.
- Knihovna YouTube Music: `music library songs.csv` -> playlist.

Celý Takeout (kanál, komentáře, odběry...) se NIKDY nepouští do Spotify
importu -- dřív z něj vzniklo 22 prázdných playlistů (živě nahlášeno).
"""

from __future__ import annotations

import csv
import html
import io
import json
import re
import zipfile
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

SOURCE = "ytmusic-history"
ASSUMED_MS = 180_000  # 3 minuty -- Takeout délku poslechu nemá
LIBRARY_PLAYLIST = "YouTube Music · Knihovna"

# "Watched X" (EN), "Zhlédnuto X" a podobně v jiných jazycích Takeoutu.
_VERB = re.compile(
    r"^(?:Watched|Zhlédnuto|Zhlédli jste video|Zhlédli jste|Shlédnuto|Sledováno|Viewed|Angesehen|Visto|Regardé)\s+", re.I
)


@dataclass
class TakeoutImport:
    is_takeout: bool = False
    plays: list[dict[str, Any]] = field(default_factory=list)
    history_found: bool = False
    library: list[tuple[str, str, str | None, int | None]] = field(default_factory=list)


def _entries(data: Any) -> list[dict[str, Any]]:
    return [e for e in data if isinstance(e, dict)] if isinstance(data, list) else []


def _is_history(entries: list[dict[str, Any]]) -> bool:
    return any("header" in e and "time" in e for e in entries[:50])


def _clean_artist(name: str) -> str:
    return re.sub(r"\s*-\s*Topic$", "", name or "").strip()


def _is_music(header: str, channel: str) -> bool:
    """YouTube Music celé; z běžného YouTube jen oficiální zvukové stopy
    (automatický kanál "Interpret - Topic") -- ostatní videa ne (vlogy,
    návody... by se jinak pomíchaly s hudbou)."""
    return header == "YouTube Music" or bool(re.search(r"\s-\sTopic$", channel or ""))


def parse(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """JSON historie -> záznamy ve tvaru Spotify historie (`spotify_history`)."""
    plays: list[dict[str, Any]] = []
    for e in entries:
        subtitles = e.get("subtitles") or []
        channel = subtitles[0].get("name") if subtitles and isinstance(subtitles[0], dict) else ""
        if not _is_music(e.get("header") or "", channel or ""):
            continue
        title = _VERB.sub("", (e.get("title") or "").strip()).strip()
        artist = _clean_artist(channel or "")
        if not title or not artist or not e.get("time") or title.startswith("http"):
            continue  # smazané video / reklama
        plays.append({"ts": e["time"], "ms": ASSUMED_MS, "assumed": True, "track": title, "artist": artist, "album": None, "spotify_id": None})
    return plays


# --- HTML historie (výchozí formát Takeoutu) ---------------------------------

_HEADER = re.compile(r'<p class="mdl-typography--title">(.*?)<br', re.S)
_CONTENT = re.compile(r'<div class="content-cell[^"]*mdl-typography--body-1">(.*?)</div>', re.S)
_LINK = re.compile(r"<a [^>]*>(.*?)</a>", re.S)
_CS_MONTH_DATE = re.compile(r"(\d{1,2})\.\s*(\d{1,2})\.\s*(\d{4})\s+(\d{1,2}):(\d{2}):(\d{2})\s*([A-ZČŘŠŽÁÉÍÓÚÝ]+)?")
_EN_DATE = re.compile(r"([A-Z][a-z]{2})\s+(\d{1,2}),\s+(\d{4}),\s+(\d{1,2}):(\d{2}):(\d{2})\s*([AP]M)?\s*([A-Z]+)?")
_EN_MONTHS = {m: i for i, m in enumerate(["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"], 1)}
# Středoevropský čas (Takeout píše čas zóny účtu): SELČ/CEST = UTC+2, SEČ/CET = UTC+1.
_TZ = {"SELČ": 2, "CEST": 2, "SEČ": 1, "CET": 1, "UTC": 0, "GMT": 0}


def _text(fragment: str) -> str:
    # Google píše do času úzké nezalomitelné mezery (U+202F) -- na obyčejné.
    text = html.unescape(re.sub(r"<[^>]+>", "", fragment))
    return re.sub(r"[\xa0  ]", " ", text).strip()


def _parse_date(text: str) -> str | None:
    m = _CS_MONTH_DATE.search(text)
    if m:
        d, mo, y, h, mi, s, tz = m.groups()
        local = datetime(int(y), int(mo), int(d), int(h), int(mi), int(s))
    else:
        m = _EN_DATE.search(text)
        if not m:
            return None
        mon, d, y, h, mi, s, ampm, tz = m.groups()
        hour = int(h) % 12 + (12 if ampm == "PM" else 0) if ampm else int(h)
        local = datetime(int(y), _EN_MONTHS.get(mon, 1), int(d), hour, int(mi), int(s))
    # Bez zóny: letní čas podle měsíce (duben-říjen +2), jinak +1.
    offset = _TZ.get((tz or "").upper(), 2 if 4 <= local.month <= 10 else 1)
    return (local - timedelta(hours=offset)).replace(tzinfo=timezone.utc).isoformat().replace("+00:00", "Z")


def parse_html(text: str) -> list[dict[str, Any]]:
    plays: list[dict[str, Any]] = []
    # Buňky podle začátku (konec `</div></div></div>` je křehký).
    for cell in text.split('class="outer-cell')[1:]:
        header = _HEADER.search(cell)
        content = _CONTENT.search(cell)
        if not header or not content:
            continue
        body = content.group(1)
        links = _LINK.findall(body)
        if len(links) < 2:
            continue  # smazané video nemá kanál
        if not _is_music(_text(header.group(1)), _text(links[1])):
            continue
        title, artist = _text(links[0]), _clean_artist(_text(links[1]))
        ts = _parse_date(_text(body.split("<br>")[-2] if "<br>" in body else body))
        if title and artist and ts and not title.startswith("http"):
            plays.append({"ts": ts, "ms": ASSUMED_MS, "assumed": True, "track": title, "artist": artist, "album": None, "spotify_id": None})
    return plays


def _library_csv(text: str) -> list[tuple[str, str, str | None, int | None]]:
    rows = []
    for row in csv.DictReader(io.StringIO(text)):
        title = (row.get("Song Title") or row.get("Název skladby") or "").strip()
        artist = (row.get("Artist Name 1") or row.get("Jméno interpreta 1") or "").strip()
        album = (row.get("Album Title") or row.get("Název alba") or "").strip() or None
        if title and artist:
            rows.append((artist, title, album, None))
    return rows


def read_takeout(raw: bytes) -> TakeoutImport:
    """Rozpozná Takeout (ZIP / samotný soubor historie) a vytáhne z něj
    poslechy YouTube Music a knihovnu."""
    out = TakeoutImport()
    if raw[:2] == b"PK":
        from app.uploads import check_zip

        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as zf:
                check_zip(zf)
                names = [i.filename for i in zf.infolist()]
                lower = [n.lower() for n in names]
                out.is_takeout = any(
                    n.startswith("takeout/") or "youtube and youtube music/" in n or "youtube a youtube music/" in n
                    for n in lower
                )
                if not out.is_takeout:
                    return out
                for name, low in zip(names, lower):
                    base = low.rsplit("/", 1)[-1]
                    is_history = "histor" in base and ("sledov" in base or "watch" in base)
                    if is_history and base.endswith(".json"):
                        entries = _entries(json.loads(zf.read(name).decode("utf-8-sig")))
                        if _is_history(entries):
                            out.history_found = True
                            out.plays += parse(entries)
                    elif is_history and base.endswith(".html"):
                        out.history_found = True
                        out.plays += parse_html(zf.read(name).decode("utf-8", errors="replace"))
                    elif base.endswith(".csv") and "music library songs" in base:
                        out.library += _library_csv(zf.read(name).decode("utf-8-sig", errors="replace"))
        except (zipfile.BadZipFile, ValueError, UnicodeDecodeError):
            return out
        return out
    # Samotný soubor historie (JSON nebo HTML).
    try:
        text = raw.decode("utf-8-sig")
    except UnicodeDecodeError:
        return out
    if text.lstrip().startswith("<"):
        if "mdl-typography--title" in text:
            out.is_takeout = out.history_found = True
            out.plays = parse_html(text)
        return out
    try:
        entries = _entries(json.loads(text))
    except ValueError:
        return out
    if _is_history(entries):
        out.is_takeout = out.history_found = True
        out.plays = parse(entries)
    return out
