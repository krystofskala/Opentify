"""Kontrola stažených souborů přes Open Shazam: je v souboru opravdu ta
skladba, za kterou se vydává? (Nalezeno živě: část stažených souborů byla
jiná skladba nebo poškozená.)

Pro každý soubor (stažené z YouTube/Soulseeku i vlastní knihovna) vezme
15 s ze středu, nechá je rozpoznat stejně anonymně jako Open Shazam (jen
otisk, přes Mullvad VPN) a porovná interpreta a název s tím, co má skladba
v katalogu. Nic nemaže ani nemění -- jen zapíše zprávu
`/data/verify_downloads.json` (průběžně, jde přerušit a pustit znovu --
hotové přeskočí).

Spuštění (v kontejneru api):  python -m app.tools.verify_downloads
"""

from __future__ import annotations

import asyncio
import difflib
import json
import re
import unicodedata
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording, Release
from app.recognize import RecognizeError, recognize

REPORT = Path("/data/verify_downloads.json")
PROVIDERS = ("youtube", "slskd", "musicbrainz-local", "local")
# Vlastní nahrávky, které Shazam znát nemůže (malá česká kapela uživatelova
# táty, nikde online) -- nekontrolují se, ať je "rozpoznání" cizí skladby
# nikdy neoznačí k výměně. Porovnává se normalizovaný název alba.
PROTECTED_RELEASES = {"kde zustal raj"}
PAUSE_SECONDS = 4.0


def _norm(text: str) -> str:
    text = unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().lower()
    text = re.sub(r"\(.*?\)|\[.*?\]", " ", text)  # (Remastered), [Live]...
    text = re.sub(r"\b(feat|ft|with|remaster(ed)?|version|edit|mix|live)\b.*", " ", text)
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def _similar(a: str, b: str) -> float:
    a, b = _norm(a), _norm(b)
    if not a or not b:
        return 0.0
    if a in b or b in a:
        return 1.0
    return difflib.SequenceMatcher(None, a, b).ratio()


async def _snippet(path: str) -> bytes | None:
    # Střed skladby (intro bývá ticho/mluvené), 15 s, malé mp3.
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-v", "error", "-ss", "45", "-i", path, "-t", "15", "-ac", "1", "-ar", "22050",
        "-b:a", "64k", "-f", "mp3", "pipe:1",
        stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
    )
    out, _ = await asyncio.wait_for(proc.communicate(), timeout=60)
    if len(out) < 20000:  # kratší skladba než 45 s -> od začátku
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-v", "error", "-i", path, "-t", "15", "-ac", "1", "-ar", "22050", "-b:a", "64k",
            "-f", "mp3", "pipe:1", stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE,
        )
        out, _ = await asyncio.wait_for(proc.communicate(), timeout=60)
    return out or None


async def main() -> None:
    report: dict[str, dict] = json.loads(REPORT.read_text()) if REPORT.exists() else {}
    with Session(engine) as session:
        rows = session.exec(
            select(MediaAsset, Recording, Artist, Release)
            .join(Recording, Recording.id == MediaAsset.recording_id)
            .join(Artist, Artist.id == Recording.artist_id, isouter=True)
            .join(Release, Release.id == Recording.release_id, isouter=True)
            .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
            .where(MediaAsset.source_provider.in_(PROVIDERS))  # type: ignore[union-attr]
        ).all()
    # Stažené napřed (tam jsou známé chyby), vlastní knihovna potom.
    rows = sorted(rows, key=lambda row: row[0].source_provider in ("musicbrainz-local", "local"))
    todo = [(a, r, ar, rel) for a, r, ar, rel in rows if r.id not in report and a.storage_path]
    print(f"celkem {len(rows)}, zbývá {len(todo)}", flush=True)
    for i, (asset, rec, artist, release) in enumerate(todo, 1):
        expected_artist = artist.name if artist else ""
        entry: dict = {
            "title": rec.title,
            "artist": expected_artist,
            "album": release.title if release else None,
            "provider": asset.source_provider,
            "path": asset.storage_path,
        }
        if release and _norm(release.title) in PROTECTED_RELEASES:
            entry["verdict"] = "protected"
            report[rec.id] = entry
            continue
        try:
            clip = await _snippet(asset.storage_path)
            match = await recognize(clip) if clip else None
            if clip is None:
                entry["verdict"] = "broken"  # soubor nejde dekódovat
            elif match is None:
                entry["verdict"] = "unknown"  # Shazam nepoznal (neznamená chybu)
            else:
                t = _similar(match.title, rec.title)
                a = _similar(match.artist, expected_artist)
                entry.update(gotTitle=match.title, gotArtist=match.artist, titleScore=round(t, 2), artistScore=round(a, 2))
                entry["verdict"] = "ok" if t >= 0.6 or (a >= 0.6 and t >= 0.4) else "mismatch"
        except RecognizeError as exc:
            entry["verdict"] = "error"
            entry["error"] = str(exc)
        except Exception as exc:  # noqa: BLE001 - jedna chyba nezastaví celou kontrolu
            entry["verdict"] = "error"
            entry["error"] = f"{type(exc).__name__}: {exc}"
        report[rec.id] = entry
        if i % 10 == 0 or i == len(todo):
            REPORT.write_text(json.dumps(report, ensure_ascii=False, indent=1))
            counts: dict[str, int] = {}
            for e in report.values():
                counts[e["verdict"]] = counts.get(e["verdict"], 0) + 1
            print(f"{i}/{len(todo)} {counts}", flush=True)
        await asyncio.sleep(PAUSE_SECONDS)


if __name__ == "__main__":
    asyncio.run(main())
