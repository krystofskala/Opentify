"""Kontrola staženého souboru: je v něm opravdu ta skladba?

1. Po každém stažení (worker) se porovná délka souboru s délkou skladby
   v katalogu -- zadarmo, hned, nic nejde ven. Špatná stažení z YouTube se
   délkou skoro vždycky liší (jiná písnička, živák, klip s intrem, celé
   album v jednom souboru).
2. Jen podezřelé (délka nesedí) poslechne Open Shazam (anonymně přes
   Mullvad, jako `app/tools/verify_downloads.py`).
3. Ručně: "Něco nesedí?" v přehrávači -> `check_recording` pro jednu skladbu.

Výsledek jde do stejné zprávy jako hromadná kontrola
(`/data/db/verify_downloads.json`) -> Profil › Kontrola stažených. Nic se
samo nemaže ani nenahrazuje.
"""

from __future__ import annotations

import asyncio
import fcntl
import json
import logging
from contextlib import contextmanager
from pathlib import Path
from typing import Any, Callable

from sqlmodel import Session

from app.db import engine
from app.models import Artist, MediaAsset, Recording, Release

logger = logging.getLogger(__name__)

REPORT = Path("/data/db/verify_downloads.json")
_LOCK = Path("/data/db/verify_downloads.lock")
# Délka "nesedí": o víc než 20 s A zároveň o víc než 10 % (krátké skladby
# mají přirozeně pár sekund rozdíl mezi edicemi, dlouhé klidně 15 s).
_MIN_DIFF_S = 20.0
_MIN_DIFF_RATIO = 0.10


@contextmanager
def _locked():
    # api i víc kopií workeru zapisují do stejné zprávy -- zámek přes soubor
    # na sdíleném svazku (flock funguje napříč kontejnery na jednom stroji).
    with open(_LOCK, "a") as handle:
        fcntl.flock(handle, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(handle, fcntl.LOCK_UN)


def read_report() -> dict[str, dict]:
    try:
        return json.loads(REPORT.read_text())
    except (FileNotFoundError, json.JSONDecodeError):
        return {}


def update_report(change: Callable[[dict[str, dict]], Any]) -> Any:
    """Přečte, upraví a zapíše zprávu pod zámkem; vrací výsledek `change`."""
    with _locked():
        report = read_report()
        result = change(report)
        tmp = REPORT.with_suffix(".tmp")
        tmp.write_text(json.dumps(report, ensure_ascii=False, indent=1))
        tmp.replace(REPORT)
        return result


async def file_duration_s(path: str) -> float | None:
    proc = await asyncio.create_subprocess_exec(
        "ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path,
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    out, _ = await asyncio.wait_for(proc.communicate(), timeout=30)
    try:
        return float(out.decode().strip())
    except ValueError:
        return None


def _context(recording_id: str) -> dict | None:
    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        rec = session.get(Recording, recording_id)
        if asset is None or rec is None or not asset.storage_path:
            return None
        artist = session.get(Artist, rec.artist_id) if rec.artist_id else None
        release = session.get(Release, rec.release_id) if rec.release_id else None
        return {
            "title": rec.title,
            "artist": artist.name if artist else "",
            "album": release.title if release else None,
            "provider": asset.source_provider,
            "path": asset.storage_path,
            "expectedMs": rec.duration_ms,
        }


async def _expected_ms(recording_id: str, ctx: dict) -> int | None:
    """Délka z katalogu; chybí-li, dohledá se na Deezeru (jen jistá shoda,
    viz verify_file.resolve_duration) a uloží k nahrávce."""
    if ctx["expectedMs"]:
        return ctx["expectedMs"]
    from app.library.verify_file import Target, resolve_duration

    ms, _dz = await resolve_duration(
        Target(recording_id=recording_id, title=ctx["title"], artist=ctx["artist"], album=ctx.get("album"), expected_ms=None)
    )
    if not ms:
        return None
    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
        if rec is not None and not rec.duration_ms:
            rec.duration_ms = ms
            session.add(rec)
            session.commit()
    return ms


def _duration_off(expected_ms: int | None, actual_s: float | None) -> bool:
    if not expected_ms or actual_s is None:
        return False
    expected_s = expected_ms / 1000
    diff = abs(actual_s - expected_s)
    return diff > _MIN_DIFF_S and diff > _MIN_DIFF_RATIO * expected_s


async def _shazam(entry: dict) -> None:
    """Doplní do `entry` verdikt Shazamu (ok / mismatch / unknown / broken / error)."""
    from app.recognize import RecognizeError, recognize
    from app.tools.verify_downloads import PROTECTED_ARTISTS, PROTECTED_RELEASES, _norm, _similar, _snippet

    if _norm(entry.get("album") or "") in PROTECTED_RELEASES or _norm(entry["artist"]) in PROTECTED_ARTISTS:
        entry["verdict"] = "protected"
        return
    try:
        clip = await _snippet(entry["path"])
        match = await recognize(clip) if clip else None
        if clip is None:
            entry["verdict"] = "broken"
        elif match is None:
            entry["verdict"] = "unknown"
        else:
            t = _similar(match.title, entry["title"])
            a = _similar(match.artist, entry["artist"])
            entry.update(gotTitle=match.title, gotArtist=match.artist, titleScore=round(t, 2), artistScore=round(a, 2))
            entry["verdict"] = "ok" if t >= 0.6 or (a >= 0.6 and t >= 0.4) else "mismatch"
    except RecognizeError as exc:
        entry["verdict"] = "error"
        entry["error"] = str(exc)


def _store(recording_id: str, entry: dict) -> None:
    def change(report: dict[str, dict]) -> None:
        report[recording_id] = entry  # nová kontrola = nové posouzení (review se maže)

    update_report(change)


async def check_recording(recording_id: str, *, manual: bool = False) -> dict | None:
    """Délka + Shazam pro jednu skladbu. Ručně (`manual`) se Shazam ptá vždy,
    po stažení jen když délka nesedí."""
    ctx = _context(recording_id)
    if ctx is None:
        return None
    entry = dict(ctx)
    entry["expectedMs"] = ctx["expectedMs"] = await _expected_ms(recording_id, ctx)
    actual = await file_duration_s(ctx["path"])
    entry["actualMs"] = int(actual * 1000) if actual is not None else None
    off = _duration_off(ctx["expectedMs"], actual)
    entry["durationOff"] = off
    if actual is None:
        entry["verdict"] = "broken"
    elif off or manual:
        await _shazam(entry)
        # Shazam nepoznal / nedostupný, ale délka nesedí -> pořád podezřelé.
        # Timeout / výpadek Shazamu nic neříká o souboru (28 z 93 "podezřelých"
        # byly jen timeouty) -- podezřelé je jen "Shazam nepoznal".
        if off and entry["verdict"] == "unknown":
            entry["verdict"] = "suspect"
    else:
        # Po stažení a délka sedí. Byl-li to dřívější nález ("Stáhnout
        # znovu"), nové stažení ho uzavře; jinak se nic nezapisuje.
        if recording_id not in read_report():
            return entry
        entry["verdict"] = "ok"
    entry["source"] = "manual" if manual else "download"
    _store(recording_id, entry)
    return entry


async def check_after_download(recording_id: str) -> None:
    """Volá worker po úspěšném stažení (fire-and-forget)."""
    try:
        entry = await check_recording(recording_id)
        if entry and entry.get("verdict") not in (None, "ok"):
            logger.warning("stažený soubor %s podezřelý: %s", recording_id, entry.get("verdict"))
    except Exception:  # noqa: BLE001 - kontrola je bonus, nesmí shodit worker
        logger.exception("kontrola staženého souboru %s selhala", recording_id)
