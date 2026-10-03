"""Celé album ze Soulseeku jako JEDNA složka od jednoho člověka.

Po skladbách se každá hledá zvlášť -- album pak bývá poskládané z různých
verzí (remaster, živá, jiná edice) od různých lidí. Tady se hledá
"interpret album", odpovědi se seskupí po složkách (uživatel + cesta) a ke
každé skladbě alba se ve složce najde soubor (název + délka). Vyhraje složka,
která pokryje nejvíc skladeb v nejlepší kvalitě; skladby si zapamatují
`preferredSource` a worker je stáhne rovnou z ní (`SlskdProvider.resolve`).
Co ve složce chybí, dohledá se po skladbách jako dřív.
"""

from __future__ import annotations

import logging
import re
from pathlib import Path
from typing import Any

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, Recording, Release
from app.download_match import _covered, artist_in, core_tokens, duration_ok, match_label, tokens
from app.providers import SlskdProvider, TrackMetadata, _junk_reason, _normalize

logger = logging.getLogger("vault.album_download")

_EXT_QUALITY = {".flac": 3.0, ".mp3": 2.0, ".m4a": 1.5, ".ogg": 1.5}
MIN_COVERAGE = 0.6


def _folder(filename: str) -> str:
    return filename.replace("\\", "/").rsplit("/", 1)[0]


def _match(rec_title: str, duration_ms: int | None, files: list[dict], artist: str = "", album: str = "") -> dict | None:
    """Soubor skladby ve složce alba -- stejná přísná pravidla jako při
    hledání po skladbách (app/download_match.py): přesný název, žádná jiná
    verze, délka sedí (živě: "Old King" se stáhl jako "Harvest Moon")."""
    target = duration_ms / 1000 if duration_ms else None
    best: tuple[float, dict] | None = None
    for f in files:
        path = f["filename"].replace("\\", "/")
        name = path.rsplit("/", 1)[-1]
        folder = path.rsplit("/", 2)[-2] if path.count("/") else ""
        ext = Path(name).suffix.lower()
        length = float(f.get("length") or 0) or None
        if _junk_reason(f["filename"], name, ext, int(f.get("size") or 0), length, f.get("bitRate")):
            continue
        # Bez délky v souboru jen tady (složka alba) -- ověří ji kontrola po stažení.
        if target and length is not None and not duration_ok(target, length, strict=False):
            continue
        if match_label(rec_title, name, artist=artist, album=album, context=folder):
            continue
        score = 2.0 if target and length and duration_ok(target, length) else 1.0
        if best is None or score > best[0]:
            best = (score, f)
    return best[1] if best else None


# Soubor pojmenovaný jen číslem stopy: "01", "01.", "Track 01", "01 - Track 01",
# "Stopa 3", "CD1 - 05" (rip celého alba bez názvů skladeb).
_GENERIC_NAME = re.compile(
    r"^\s*(?:(?:cd|disc|disk)\s*\d+\s*[-_. ]*)?(?:(?:track|trk|stopa|skladba|titel|piste|pista|traccia)\s*[-_.#]*\s*)?"
    r"(\d{1,3})\s*[-_.]*\s*(?:(?:track|trk|stopa|skladba|titel|piste|pista|traccia)\s*[-_.#]*\s*\d{1,3})?\s*$",
    re.I,
)


def generic_track_name(stem: str) -> int | None:
    """Číslo stopy, když je to celé jméno souboru/tagu ("Track 07" -> 7)."""
    m = _GENERIC_NAME.match(stem or "")
    return int(m.group(1)) if m else None


def _match_numbered(
    recs: list[tuple[str, str, int | None, int | None]], files: list[dict], folder: str, artist: str, album: str
) -> dict[str, dict]:
    """Složka alba se soubory bez názvů skladeb ("01.flac", "Track 01.mp3"):
    vezme se podle čísla stopy, jen když sedí VŠECHNO -- interpret i album
    v cestě, stejný počet souborů jako skladeb a délka každé stopy přesně
    (celé pořadí délek je otisk alba). Po stažení to ještě ověří otisk
    proti ukázce z Deezeru."""
    path_tokens = set(tokens(folder))
    if not artist_in(artist, folder) or not all(_covered(w, path_tokens) for w in core_tokens(album)):
        return {}
    numbers = [n for _rid, _t, _d, n in recs]
    if None in numbers or len(set(numbers)) != len(numbers) or len(files) != len(recs):
        return {}
    by_number: dict[int, dict] = {}
    for f in files:
        name = f["filename"].replace("\\", "/").rsplit("/", 1)[-1]
        ext = Path(name).suffix.lower()
        number = generic_track_name(Path(name).stem)
        length = float(f.get("length") or 0) or None
        if number is None or number in by_number or length is None:
            return {}
        if _junk_reason(f["filename"], name, ext, int(f.get("size") or 0), length, f.get("bitRate")):
            return {}
        by_number[number] = f
    matches: dict[str, dict] = {}
    for rid, _title, dur, number in recs:
        f = by_number.get(number)  # type: ignore[arg-type]
        if f is None or not dur or not duration_ok(dur / 1000, float(f["length"]), strict=True):
            return {}
        matches[rid] = f
    return matches


def _clear_plan(recording_ids: list[str]) -> None:
    """Starý plán (jiná / špatná složka) pryč -- skladba se pak hledá sama."""
    with Session(engine) as session:
        for rid in recording_ids:
            rec = session.get(Recording, rid)
            if rec is not None and (rec.external_refs or {}).get("preferredSource"):
                rec.external_refs = {k: v for k, v in rec.external_refs.items() if k != "preferredSource"}
                session.add(rec)
        session.commit()


async def plan_album(release_id: str) -> dict[str, Any]:
    """Najde nejlepší složku alba a skladbám uloží `preferredSource`."""
    with Session(engine) as session:
        release = session.get(Release, release_id)
        if release is None:
            return {"found": False, "reason": "album neexistuje"}
        artist = session.get(Artist, release.artist_id)
        rows = session.exec(select(Recording).where(Recording.release_id == release_id)).all()
        recs = [(r.id, r.title, r.duration_ms) for r in rows]
        numbered_recs = [(r.id, r.title, r.duration_ms, r.track_number) for r in rows]
        album, artist_name = release.title, artist.name if artist else ""
    if not recs:
        return {"found": False, "reason": "album nemá skladby"}
    query = TrackMetadata(recording_id="", title=album, artist_name=artist_name).soulseek_query
    slskd = SlskdProvider()
    try:
        responses = await slskd.search_raw(query)
    except Exception as exc:  # noqa: BLE001
        logger.info("album %s: hledání selhalo: %s", release_id, exc)
        return {"found": False, "reason": "Soulseek nedostupný"}

    folders: dict[tuple[str, str], dict[str, Any]] = {}
    for resp in responses:
        user = resp["username"]
        for f in resp.get("files", []):
            ext = Path(f.get("filename", "").replace("\\", "/")).suffix.lower()
            if ext not in _EXT_QUALITY:
                continue
            key = (user, _folder(f["filename"]))
            entry = folders.setdefault(
                key, {"files": [], "free": bool(resp.get("hasFreeUploadSlot")), "speed": int(resp.get("uploadSpeed") or 0)}
            )
            entry["files"].append({**f, "_q": _EXT_QUALITY[ext]})

    # Skladby alba bez duplicit (katalog má občas stejnou skladbu 2x).
    distinct = len({_normalize(title) for _rid, title, _dur in recs}) or 1
    best: tuple[float, tuple[str, str], dict[str, dict]] | None = None
    for key, entry in folders.items():
        # Složka s celou diskografií ("music/twenty one pilots") není album --
        # podle názvu by z ní šla "Trees" z jiné desky (živě: Trench 28/28).
        if len(entry["files"]) > distinct * 1.6 + 3:
            continue
        matches = {rid: m for rid, title, dur in recs if (m := _match(title, dur, entry["files"], artist_name, album))}
        if len(matches) / len(recs) < MIN_COVERAGE:
            # Rip bez názvů skladeb ("01.flac"): podle čísla stopy, když sedí
            # interpret, album, počet skladeb i délka každé z nich.
            matches = _match_numbered(numbered_recs, entry["files"], key[1], artist_name, album) or matches
        coverage = len(matches) / len(recs)
        if coverage < MIN_COVERAGE:
            continue
        quality = sum(m["_q"] for m in matches.values()) / len(matches)
        score = coverage * 1000 + quality * 50 + (100 if entry["free"] else 0) + min(entry["speed"], 5_000_000) / 100_000
        if best is None or score > best[0]:
            best = (score, key, matches)
    if best is None:
        _clear_plan([rid for rid, _t, _d in recs])
        logger.info("album %s ('%s'): žádná složka nepokryla %.0f %% skladeb", release_id, query, MIN_COVERAGE * 100)
        return {"found": False, "reason": "složka s celým albem nenalezena", "total": len(recs)}

    _score, (user, folder), matches = best
    _clear_plan([rid for rid, _t, _d in recs if rid not in matches])
    with Session(engine) as session:
        for rid, f in matches.items():
            rec = session.get(Recording, rid)
            if rec is None:
                continue
            rec.external_refs = {
                **(rec.external_refs or {}),
                "preferredSource": {
                    "username": user,
                    "filename": f["filename"],
                    "size": f.get("size", 0),
                    "bitrate_kbps": f.get("bitRate"),
                },
            }
            session.add(rec)
        session.commit()
    logger.info("album %s: složka %s od %s, %d/%d skladeb", release_id, folder, user, len(matches), len(recs))
    return {"found": True, "matched": len(matches), "total": len(recs), "folder": folder.rsplit("/", 1)[-1]}


ALBUM_RETRY_HOURS = 24


async def plan_album_for_recording(recording_id: str) -> dict[str, Any] | None:
    """Záloha stahování po skladbách: když skladba sama nejde najít, zkusit
    složku jejího alba (`plan_album`) -- jednou za den na album, ať každá
    chybějící skladba nespouští stejné hledání znovu. Vrátí `preferredSource`
    skladby (nebo None)."""
    from datetime import datetime, timedelta, timezone

    from app.utils import utcnow

    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
        if rec is None or not rec.release_id:
            return None
        release = session.get(Release, rec.release_id)
        if release is None:
            return None
        refs = release.external_refs or {}
        tried = refs.get("albumFolderTriedAt")
        if tried:
            when = datetime.fromisoformat(tried)
            when = when if when.tzinfo else when.replace(tzinfo=timezone.utc)
            now = utcnow()
            now = now if now.tzinfo else now.replace(tzinfo=timezone.utc)
            if now - when < timedelta(hours=ALBUM_RETRY_HOURS):
                return (rec.external_refs or {}).get("preferredSource")
        release.external_refs = {**refs, "albumFolderTriedAt": utcnow().isoformat()}
        session.add(release)
        session.commit()
        release_id = release.id
    plan = await plan_album(release_id)
    logger.info("záloha složkou alba pro %s: %s", recording_id, plan)
    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
        return (rec.external_refs or {}).get("preferredSource") if rec else None
