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
from pathlib import Path
from typing import Any

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, Recording, Release
from app.providers import SlskdProvider, TrackMetadata, _normalize, _title_tokens

logger = logging.getLogger("vault.album_download")

_EXT_QUALITY = {".flac": 3.0, ".mp3": 2.0, ".m4a": 1.5, ".ogg": 1.5}
MIN_COVERAGE = 0.6


def _folder(filename: str) -> str:
    return filename.replace("\\", "/").rsplit("/", 1)[0]


def _match(rec_title: str, duration_ms: int | None, files: list[dict]) -> dict | None:
    wanted = _title_tokens(rec_title)
    best: tuple[float, dict] | None = None
    for f in files:
        name = f["filename"].replace("\\", "/").rsplit("/", 1)[-1]
        have = set(_normalize(Path(name).stem).split())
        if not wanted or len(wanted & have) < max(1, round(len(wanted) * 0.8)):
            continue
        length = f.get("length")
        if length and duration_ms and abs(float(length) - duration_ms / 1000) > max(20.0, duration_ms / 1000 * 0.15):
            continue
        # Kratší název souboru = přesnější shoda ("Drown" vs "Drown (Live)").
        score = len(wanted & have) - 0.1 * len(have - wanted)
        if best is None or score > best[0]:
            best = (score, f)
    return best[1] if best else None


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
        recs = [
            (r.id, r.title, r.duration_ms)
            for r in session.exec(select(Recording).where(Recording.release_id == release_id)).all()
        ]
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
        matches = {rid: m for rid, title, dur in recs if (m := _match(title, dur, entry["files"]))}
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
