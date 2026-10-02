"""Historie poslechů z YouTube Music (Google Takeout).

Takeout › "YouTube a YouTube Music" › historie, formát JSON (výchozí je HTML
-- v Takeoutu přepnout "Formát historie" na JSON). Soubor `watch-history.json`
(česky třeba `historie sledování.json`) je seznam záznamů:

    {"header": "YouTube Music", "title": "Watched Trees",
     "subtitles": [{"name": "Twenty One Pilots - Topic"}], "time": "2024-...Z"}

Bere se jen YouTube Music (ne obyčejná videa). Takeout neříká, jak dlouho
skladba hrála -- každé přehrání se počítá jako `ASSUMED_MS`.
"""

from __future__ import annotations

import io
import json
import re
import zipfile
from typing import Any

SOURCE = "ytmusic-history"
ASSUMED_MS = 180_000  # 3 minuty -- Takeout délku poslechu nemá

# "Watched X" (EN), "Zhlédnuto X" a podobně v jiných jazycích Takeoutu.
_VERB = re.compile(r"^(?:Watched|Zhlédnuto|Zhlédli jste|Sledováno|Viewed|Angesehen|Visto|Regardé)\s+", re.I)


def _entries(data: Any) -> list[dict[str, Any]]:
    return [e for e in data if isinstance(e, dict)] if isinstance(data, list) else []


def _is_history(entries: list[dict[str, Any]]) -> bool:
    return any("header" in e and "time" in e for e in entries[:50])


def parse(entries: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Záznamy ve stejném tvaru jako Spotify historie (`spotify_history`)."""
    plays: list[dict[str, Any]] = []
    for e in entries:
        if (e.get("header") or "") != "YouTube Music":
            continue
        title = _VERB.sub("", (e.get("title") or "").strip()).strip()
        subtitles = e.get("subtitles") or []
        artist = (subtitles[0].get("name") if subtitles and isinstance(subtitles[0], dict) else "") or ""
        artist = re.sub(r"\s*-\s*Topic$", "", artist).strip()
        if not title or not artist or not e.get("time") or title.startswith("http"):
            continue  # smazané video / reklama
        plays.append({"ts": e["time"], "ms": ASSUMED_MS, "track": title, "artist": artist, "album": None, "spotify_id": None})
    return plays


def read_upload(raw: bytes) -> list[dict[str, Any]] | None:
    """Přehrání z Takeout ZIPu nebo samotného JSONu; `None` = není to
    YouTube historie (zkusí se jiný import)."""
    candidates: list[list[dict[str, Any]]] = []
    if raw[:2] == b"PK":
        from app.uploads import check_zip

        try:
            with zipfile.ZipFile(io.BytesIO(raw)) as zf:
                check_zip(zf)
                for info in zf.infolist():
                    name = info.filename.lower()
                    if not name.endswith(".json") or "histor" not in name and "history" not in name:
                        continue
                    try:
                        candidates.append(_entries(json.loads(zf.read(info).decode("utf-8-sig"))))
                    except (ValueError, UnicodeDecodeError):
                        continue
        except zipfile.BadZipFile:
            return None
    else:
        try:
            candidates.append(_entries(json.loads(raw.decode("utf-8-sig"))))
        except (ValueError, UnicodeDecodeError):
            return None
    history = [c for c in candidates if _is_history(c)]
    if not history:
        return None
    return [p for c in history for p in parse(c)]
