"""Export dat z Apple Music (privacy.apple.com -> "Informace o mediálních
službách Apple"): ZIP, ve kterém je další ZIP `Apple_Media_Services.zip`.

- Poslechy: `Apple Music Play Activity.csv` (řádky `PLAY_END` -- čas, délka
  přehrání, jak skončilo). Apple v něm NEMÁ interpreta, jen skladbu a album:
  interpret se doplní z knihovny (`Apple Music Library Tracks.json`), z
  přehledů ve tvaru "Interpret - Skladba" (`Play History Daily Tracks`,
  `Track Play History`), podle ostatních skladeb téhož alba a nakonec z
  katalogu appky. Co se nepovede, se NEZAHODÍ: čeká v `PendingImportPlay`
  a doplní se na pozadí (app/library/pending_plays.py, i přes iTunes).
- Knihovna Apple Music -> playlist `LIBRARY_PLAYLIST`.

Přečte se jen pár sloupců; IP adresa, poloha, zařízení, Apple ID a
podobně se zahodí hned při čtení. Poslechy jdou do `Listen` se
`source="applemusic-history"` přes `spotify_history.import_history`
(stejná váha jako každý jiný poslech, na ListenBrainz/Last.fm se neposílají).

Spuštění: `python -m app.library.apple_history <zip> [user_id]`.
"""

from __future__ import annotations

import csv
import io
import json
import sys
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any

SOURCE = "applemusic-history"
LIBRARY_PLAYLIST = "Apple Music · Knihovna"

_PLAY_ACTIVITY = "apple music play activity.csv"
_DAILY = "apple music - play history daily tracks.csv"
_TRACK_HISTORY = "apple music - track play history.csv"
_LIBRARY = "apple music library tracks.json"

# Apple -> slovník Spotify historie (`spotify_history._end_reason`).
_END_REASONS = {
    "NATURAL_END_OF_TRACK": "trackdone",
    "TRACK_SKIPPED_FORWARDS": "fwdbtn",
    "TRACK_SKIPPED_BACKWARDS": "backbtn",
    "MANUALLY_SELECTED_PLAYBACK_OF_A_DIFF_ITEM": "clickrow",
}


@dataclass
class AppleImport:
    is_apple: bool = False
    plays: list[dict[str, Any]] = field(default_factory=list)
    library: list[tuple[str, str, str | None, int | None]] = field(default_factory=list)
    unresolved: int = 0  # poslechy, ke kterým se nenašel interpret


def _low(value: str | None) -> str:
    return (value or "").strip().lower()


def _files(raw: bytes, depth: int = 0) -> dict[str, bytes]:
    """Potřebné soubory z (i vnořených) ZIPů, klíč = malým písmenem jméno."""
    from app.uploads import check_zip

    out: dict[str, bytes] = {}
    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        check_zip(zf)
        for info in zf.infolist():
            base = info.filename.rsplit("/", 1)[-1].lower()
            if base in (_PLAY_ACTIVITY, _DAILY, _TRACK_HISTORY, _LIBRARY):
                out[base] = zf.read(info)
            elif base.endswith(".zip") and depth < 2 and (
                base == "apple_media_services.zip" or base == _LIBRARY + ".zip"
            ):
                out.update(_files(zf.read(info), depth + 1))
    return out


def _split_pairs(text: str) -> list[tuple[str, str]]:
    """"Interpret - Skladba" -> všechna možná rozdělení (obě strany můžou
    obsahovat " - ")."""
    return [(text[:i], text[i + 3 :]) for i in range(len(text)) if text.startswith(" - ", i)]


def _ts(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00")) if value else None
    except ValueError:
        return None


def parse(files: dict[str, bytes]) -> AppleImport:
    out = AppleImport(is_apple=_PLAY_ACTIVITY in files or _LIBRARY in files)

    # Knihovna: (skladba, album) -> interpret; skladba -> interpreti.
    by_album: dict[tuple[str, str], str] = {}
    by_title: dict[str, set[str]] = defaultdict(set)
    if _LIBRARY in files:
        for t in json.loads(files[_LIBRARY].decode("utf-8-sig")):
            title, artist = (t.get("Title") or "").strip(), (t.get("Artist") or "").strip()
            if not title or not artist:
                continue
            album = (t.get("Album") or "").strip() or None
            by_album[(_low(title), _low(album))] = artist
            by_title[_low(title)].add(artist)
            out.library.append((artist, title, album, None))

    # Přehledy "Interpret - Skladba".
    described: dict[str, set[str]] = defaultdict(set)
    for name, column in ((_DAILY, "Track Description"), (_TRACK_HISTORY, "Track Name")):
        if name not in files:
            continue
        for row in csv.DictReader(io.StringIO(files[name].decode("utf-8-sig", errors="replace"))):
            for artist, title in _split_pairs(row.get(column) or ""):
                described[_low(title)].add(artist.strip())

    if _PLAY_ACTIVITY not in files:
        return out
    rows: list[dict[str, Any]] = []
    for row in csv.DictReader(io.StringIO(files[_PLAY_ACTIVITY].decode("utf-8-sig", errors="replace"))):
        if row.get("Event Type") != "PLAY_END" or row.get("Media Type", "AUDIO") != "AUDIO":
            continue
        song = (row.get("Song Name") or "").strip()
        ms = int(float(row.get("Play Duration Milliseconds") or 0))
        start = _ts(row.get("Event Start Timestamp") or "")
        end = _ts(row.get("Event Timestamp") or "") or (start + timedelta(milliseconds=ms) if start else None)
        if not song or end is None or ms <= 0:
            continue
        rows.append(
            {
                "ts": end.astimezone(timezone.utc).isoformat().replace("+00:00", "Z"),
                "ms": ms,
                "track": song,
                "album": (row.get("Album Name") or "").strip() or None,
                "reason_end": _END_REASONS.get(row.get("End Reason Type") or "", "endplay"),
                "skipped": False,
            }
        )

    def direct(song: str, album: str | None) -> str | None:
        if (hit := by_album.get((_low(song), _low(album)))) is not None:
            return hit
        candidates = by_title[_low(song)] or described[_low(song)]
        return next(iter(candidates)) if len(candidates) == 1 else None

    # Album -> interpret podle skladeb, které už interpreta mají (Revolver
    # (Super Deluxe) -> The Beatles, i když zrovna tahle skladba v knihovně není).
    album_votes: dict[str, Counter] = defaultdict(Counter)
    for (_title, album), artist in by_album.items():
        if album:
            album_votes[album][artist] += 1
    for r in rows:
        if r["album"] and (artist := direct(r["track"], r["album"])):
            album_votes[_low(r["album"])][artist] += 1
    for r in rows:
        artist = direct(r["track"], r["album"])
        if artist is None and r["album"] and album_votes[_low(r["album"])]:
            artist = album_votes[_low(r["album"])].most_common(1)[0][0]
        if artist is None:
            # Víc kandidátů: ten, jehož album sedí.
            candidates = by_title[_low(r["track"])] | described[_low(r["track"])]
            votes = album_votes[_low(r["album"])] if r["album"] else Counter()
            fitting = [a for a in candidates if votes.get(a)]
            artist = fitting[0] if len(fitting) == 1 else None
        r["artist"] = artist
    out.plays = rows
    return out


def read_export(raw: bytes) -> AppleImport:
    """Rozpozná export Apple Music (ZIP) a vytáhne poslechy a knihovnu."""
    if raw[:2] != b"PK":
        return AppleImport()
    try:
        files = _files(raw)
    except (zipfile.BadZipFile, ValueError):
        return AppleImport()
    if not files:
        return AppleImport()
    return parse(files)


def import_export(user_id: str, result: AppleImport) -> dict[str, Any]:
    """Poslechy s interpretem hned do `Listen`; ostatní se nezahodí, ale
    čekají v `PendingImportPlay` (doplní je app/library/pending_plays.py).
    Volající nastaví `g.set_home_user` (roční playlisty)."""
    from sqlmodel import Session

    from app.db import engine
    from app.library.pending_plays import _from_catalog, save_pending
    from app.library.spotify_history import import_history

    with Session(engine) as session:
        albums = {r["album"] for r in result.plays if r.get("artist") is None and r.get("album")}
        found = {a: hit for a in albums if (hit := _from_catalog(session, a))}
    for r in result.plays:
        if r.get("artist") is None and r.get("album") in found:
            r["artist"] = found[r["album"]]
    ready = [dict(r, spotify_id=None) for r in result.plays if r.get("artist")]
    waiting = [r for r in result.plays if not r.get("artist")]
    result.unresolved = sum(1 for r in waiting if r["ms"] >= 30_000)
    out = import_history(user_id, ready, SOURCE) if ready else {"listens": 0}
    save_pending(user_id, SOURCE, waiting)
    out["pending"] = result.unresolved
    return out


def main() -> None:
    from app.home import generators as g

    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    user_id = args[1] if len(args) > 1 else g.HOME_USER_ID
    with open(args[0], "rb") as fh:
        result = read_export(fh.read())
    if not result.is_apple:
        print("Tohle není export Apple Music.")
        return
    started = datetime.now(timezone.utc)
    g.set_home_user(user_id)
    out = import_export(user_id, result)
    print(json.dumps(out, default=str), "za", round((datetime.now(timezone.utc) - started).total_seconds()), "s")


if __name__ == "__main__":
    main()
