"""Přestavba vlastní hudby (MUSIC_DIR) podle štítků souborů a složek.

Původní sken párovala každý soubor zvlášť s MusicBrainz -- výběrovky se
rozpadly do desítek alb (každá skladba k jinému původnímu albu), něco se
přiřadilo úplně jinému interpretovi a štítky se špatným kódováním
("Zemì" místo "Země") daly rozsypané názvy. Tady platí:

- jedna složka = jedno album (název z většinového štítku alba, jinak
  ze složky); víc alb ve složce jen když má každé aspoň 2 skladby,
- skladba, interpret a číslo ze štítků souboru (s opravou kódování
  cp1250 čteného jako latin1; ověřeno proti názvu souboru),
- album s víc než dvěma interprety = "Různí interpreti",
- poslechy, lajky, playlisty, Poslechnout později, zlomená srdce
  a knihovna se převedou z původní (špatné) nahrávky na novou,
- soubory na disku se nemění; před zápisem záloha databáze.

`python -m app.tools.rebuild_own_library`          -- nanečisto (výpis)
`python -m app.tools.rebuild_own_library --apply`  -- zapsat
"""

from __future__ import annotations

import difflib
import re
import sqlite3
import sys
import unicodedata
from collections import Counter, defaultdict
from datetime import datetime
from pathlib import Path

from mutagen import File as MutagenFile
from sqlalchemy import func
from sqlmodel import Session, select

from app.db import engine
from app.library.matching import find_or_create_artist, find_or_create_release
from app.library.scanner import _read_tags, _reassign_media_asset
from app.models import (
    CollectionProgress,
    LibraryEntry,
    Listen,
    ListenLater,
    MediaAsset,
    PlaylistItem,
    Recording,
    RecordingDislike,
)

LOCAL_ROOT = "/data/local-music"
VARIOUS = "Různí interpreti"
_AUDIO = {".mp3", ".flac", ".m4a", ".ogg", ".opus", ".wav", ".wma", ".aac"}
PROTECTED = {"kontrast", "kde zustal raj"}
_STRONG = set("øìùòØÌÙÒ\x8a\x8d\x8e\x9a\x9d\x9e")
_WEAK = set("èÈïÏ")
_PREFIX = re.compile(r"^\s*\d{1,3}\s*[-._)]*\s*")
# Zástupné hodnoty ve štítcích = žádná hodnota.
_PLACEHOLDERS = {"unknown", "unknown artist", "various", "various artists", "va", "neznamy", "neznamy interpret"}


def _real(value: str | None) -> str | None:
    value = (value or "").strip()
    return None if not value or _norm(value) in _PLACEHOLDERS else value


def _norm(text: str | None) -> str:
    return unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().lower().strip()


def fix_text(value: str | None, path: str) -> str | None:
    """Štítek zapsaný v cp1250, přečtený jako latin1 ("Zemì" -> "Země").
    Silné znaky (ø ì ù ò...) = oprava vždy; jen "è" = oprava, když opravený
    text lépe sedí na název souboru/složky (francouzské "Crème" zůstane)."""
    if not value:
        return value
    chars = set(value)
    if not (chars & _STRONG or chars & _WEAK):
        return value
    try:
        fixed = value.encode("latin1").decode("cp1250")
    except (UnicodeEncodeError, UnicodeDecodeError):
        return value
    if chars & _STRONG:
        return fixed
    hay = path.lower()
    before = difflib.SequenceMatcher(None, value.lower(), hay).find_longest_match(0, len(value), 0, len(hay)).size
    after = difflib.SequenceMatcher(None, fixed.lower(), hay).find_longest_match(0, len(fixed), 0, len(hay)).size
    return fixed if after > before else value


def _albumartist(path: Path) -> str | None:
    try:
        audio = MutagenFile(path, easy=True)
        values = audio.get("albumartist") if audio is not None else None
        return str(values[0]) if values else None
    except Exception:  # noqa: BLE001
        return None


def _folder_album_name(folder: str) -> str:
    name = folder.rstrip("/").rsplit("/", 1)[-1]
    return re.sub(r"[_]+", " ", name).strip()


def plan() -> list[dict]:
    with Session(engine) as session:
        assets = session.exec(
            select(MediaAsset).where(MediaAsset.source_provider.in_(("local", "musicbrainz-local")))  # type: ignore[union-attr]
        ).all()
        rows = [(a.recording_id, a.storage_path) for a in assets if a.storage_path and a.storage_path.startswith(LOCAL_ROOT)]
    known = {path for _rid, path in rows}
    # Soubory na disku bez záznamu (vypadly sloučením stejné skladby ze dvou
    # složek při první přestavbě) -- vrátit.
    backups = sorted(Path("/data/db").glob("vault.backup-*.db"))
    if backups:
        con = sqlite3.connect(str(backups[0]))  # nejstarší = stav před přestavbou
        before = {
            r[0]
            for r in con.execute(
                "select storage_path from mediaasset where source_provider in ('local','musicbrainz-local')"
            )
        }
        con.close()
        for path in sorted(before - known):
            if path and path.startswith(LOCAL_ROOT) and Path(path).exists():
                rows.append((None, path))
    folders: dict[str, list[dict]] = defaultdict(list)
    for rid, path in rows:
        p = Path(path)
        if not p.exists():
            continue
        tags = _read_tags(p)
        title = fix_text(tags.title, path) or _PREFIX.sub("", p.stem).replace("_", " ").strip()
        artist = fix_text(tags.artist, path)
        folders[str(p.parent)].append({
            "old": rid,
            "path": path,
            "title": title.strip(),
            "artist": _real(artist),
            "album": (fix_text(tags.album, path) or "").strip() or None,
            "albumartist": _real(fix_text(_albumartist(p), path)),
            "track": tags.track_number,
            "duration": tags.duration_ms,
        })

    out: list[dict] = []
    for folder, files in folders.items():
        albums = Counter(f["album"] for f in files if f["album"])
        majority = albums.most_common(1)[0][0] if albums else _folder_album_name(folder)
        keep = {a for a, n in albums.items() if n >= 2}
        for f in files:
            f["release"] = f["album"] if f["album"] in keep else majority
        by_release: dict[str, list[dict]] = defaultdict(list)
        for f in files:
            by_release[f["release"]].append(f)
        for release, group in by_release.items():
            aa = Counter(f["albumartist"] for f in group if f["albumartist"])
            artists = Counter(f["artist"] for f in group if f["artist"])
            if aa:
                release_artist = aa.most_common(1)[0][0]
            elif len(artists) > 2:
                release_artist = VARIOUS
            elif artists:
                release_artist = artists.most_common(1)[0][0]
            else:
                release_artist = _folder_album_name(folder)
            for f in group:
                f["release_artist"] = release_artist
                f["artist"] = f["artist"] or release_artist
                out.append(f)
    return out


def _protected(f: dict) -> bool:
    return any(p in _norm(x) for x in (f["artist"], f["release"], f["release_artist"], f["path"]) for p in PROTECTED)


def _remap(session: Session, old: str, new: str) -> None:
    if old == new:
        return
    for model, field in (
        (PlaylistItem, "recording_id"),
        (Listen, "recording_id"),
        (LibraryEntry, "recording_id"),
        (RecordingDislike, "recording_id"),
        (CollectionProgress, "recording_id"),
    ):
        for row in session.exec(select(model).where(getattr(model, field) == old)).all():
            setattr(row, field, new)
            session.add(row)
    for row in session.exec(select(ListenLater).where(ListenLater.kind == "track", ListenLater.target_id == old)).all():
        row.target_id = new
        session.add(row)
    session.commit()


def _recording_for(session: Session, artist, release, f: dict) -> Recording:
    """Nahrávka pro TENHLE soubor: stejná skladba na albu i na výběru jsou
    dva záznamy (každý svůj soubor). Použije se jen nahrávka tohohle alba,
    nebo taková, která ještě žádný jiný soubor nemá."""
    title = f["title"].strip()
    same = session.exec(
        select(Recording).where(Recording.artist_id == artist.id, func.lower(Recording.title) == title.lower())
    ).all()
    for rec in same:
        if rec.release_id == release.id:
            asset = session.get(MediaAsset, rec.id)
            if asset is None or asset.storage_path == f["path"]:
                return rec
    for rec in same:
        asset = session.get(MediaAsset, rec.id)
        if asset is None or asset.storage_path == f["path"] or rec.id == f["old"]:
            return rec
    rec = Recording(artist_id=artist.id, title=title, track_number=f["track"], duration_ms=f["duration"])
    session.add(rec)
    session.commit()
    session.refresh(rec)
    return rec


def backup() -> str:
    target = f"/data/db/vault.backup-{datetime.now():%Y%m%d-%H%M%S}.db"
    src = sqlite3.connect("/data/db/vault.db")
    dst = sqlite3.connect(target)
    src.backup(dst)
    dst.close()
    src.close()
    return target


def apply(items: list[dict]) -> Counter:
    stats: Counter = Counter()
    with Session(engine) as session:
        for f in items:
            if _protected(f):
                stats["protected"] += 1
                continue
            release_artist = find_or_create_artist(session, f["release_artist"])
            release = find_or_create_release(session, release_artist, f["release"])
            artist = find_or_create_artist(session, f["artist"])
            rec = _recording_for(session, artist, release, f)
            rec.release_id = release.id
            if f["track"]:
                rec.track_number = f["track"]
            session.add(rec)
            session.commit()
            if rec.id == f["old"]:
                stats["unchanged"] += 1
                continue
            old_asset = session.get(MediaAsset, f["old"]) if f["old"] else None
            _reassign_media_asset(session, old_asset, rec.id, Path(f["path"]), "local")
            if f["old"]:
                _remap(session, f["old"], rec.id)
                stats["relinked"] += 1
            else:
                stats["restored"] += 1
    return stats


def main() -> None:
    items = plan()
    releases = Counter((f["release_artist"], f["release"]) for f in items)
    print(f"souborů {len(items)}, alb {len(releases)}")
    fixed = [f for f in items if any(ch in f["path"] for ch in "ěščřžůťďň") and f["title"] in f["path"]]
    print(f"s českými znaky v názvu souboru i štítku: {len(fixed)}")
    for (artist, album), n in releases.most_common(15):
        print(f"  {n:3d}  {artist} – {album}")
    samples = [f for f in items if "Země" in f["title"] or "Marsyas" in (f["artist"] or "") or "MARSYAS" in f["path"]][:6]
    for f in samples:
        print("  ukázka:", f["artist"], "–", f["title"], "|", f["release_artist"], "–", f["release"])
    if "--apply" in sys.argv:
        print("záloha:", backup())
        print("hotovo:", dict(apply(items)))


if __name__ == "__main__":
    main()
