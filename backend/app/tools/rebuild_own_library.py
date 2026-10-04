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
# Ocásky z YouTube v názvech: "(Official Music Video) HD", "[Lyrics]", "- Lyrics".
_VIDEO_JUNK = re.compile(
    r"\s*([(\[][^)\]]*(official|video|lyrics?|audio|hd|hq)[^)\]]*[)\]]|\s-\s*(official\s+)?(music\s+)?(video|audio|lyrics?)\s*$|\bHD\b|\bHQ\b)\s*",
    re.IGNORECASE,
)
# Zástupné hodnoty ve štítcích = žádná hodnota.
_PLACEHOLDERS = {"unknown", "unknown artist", "various", "various artists", "va", "neznamy", "neznamy interpret"}


def _real(value: str | None) -> str | None:
    value = (value or "").strip()
    return None if not value or _norm(value) in _PLACEHOLDERS else value


def _norm(text: str | None) -> str:
    return unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().lower().strip()


def nfc(value: str | None) -> str | None:
    return unicodedata.normalize("NFC", value) if value else value


def fix_text(value: str | None, path: str) -> str | None:
    """Štítek zapsaný v cp1250, přečtený jako latin1 ("Zemì" -> "Země").
    Silné znaky (ø ì ù ò...) = oprava vždy; jen "è" = oprava, když opravený
    text lépe sedí na název souboru/složky (francouzské "Crème" zůstane)."""
    if not value:
        return value
    value = nfc(value)
    chars = set(value)
    if not (chars & _STRONG or chars & _WEAK):
        return value
    try:
        fixed = nfc(value.encode("latin1").decode("cp1250"))
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
    """Čistý název složky: bez "l Audio l 320Kbps l ..." a podtržítek."""
    name = nfc(folder.rstrip("/").rsplit("/", 1)[-1]) or ""
    name = re.split(r"\s+l\s+", name)[0]
    name = re.sub(r"[_]+", " ", name).strip()
    return name


def _folder_artist_album(folder: str) -> tuple[str | None, str]:
    """"Seafret - Give Me Something [EP] (2014)" -> ("Seafret", "Give Me Something [EP]")."""
    name = _folder_album_name(folder)
    if " - " in name:
        artist, album = name.split(" - ", 1)
        album = re.sub(r"\s*\((19|20)\d{2}\)\s*$", "", album).strip()
        return artist.strip() or None, album or name
    return None, name


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
        title = fix_text(tags.title, path) or nfc(_PREFIX.sub("", p.stem).replace("_", " ").strip())
        artist = fix_text(tags.artist, path)
        if not _real(artist) and " - " in title:
            # Stažené z YouTube bez štítků: "Interpret - Název (Official Video) HD".
            artist, title = (x.strip() for x in title.split(" - ", 1))
        title = _VIDEO_JUNK.sub("", title).strip() or title
        folders[str(p.parent)].append({
            "old": rid,
            "path": path,
            "title": title.strip(),
            "artist": _real(artist),
            "album": _real(fix_text(tags.album, path)) and (fix_text(tags.album, path) or "").strip(),
            "albumartist": _real(fix_text(_albumartist(p), path)),
            "track": tags.track_number,
            "duration": tags.duration_ms,
        })

    out: list[dict] = []
    for folder, files in folders.items():
        albums = Counter(f["album"] for f in files if f["album"])
        folder_artist, folder_album = _folder_artist_album(folder)
        majority = albums.most_common(1)[0][0] if albums else folder_album
        keep = {a for a, n in albums.items() if n >= 2}
        for f in files:
            f["release"] = f["album"] if f["album"] in keep else majority
        by_release: dict[str, list[dict]] = defaultdict(list)
        for f in files:
            by_release[f["release"]].append(f)
        for release, group in by_release.items():
            # Pole interpreta jako seznam autorů ("Alex Eichenberger/…/Lucy
            # Rose/…"): jméno společné všem skladbám je skutečný interpret.
            credits = [set(p.strip() for p in f["artist"].split("/")) for f in group if f["artist"] and "/" in f["artist"]]
            if len(credits) >= 2 and len(credits) == len(group):
                common = set.intersection(*credits)
                named = [c for c in common if all(_norm(c) in _norm(Path(f["path"]).stem + " " + folder) for f in group)]
                if len(named) == 1:
                    for f in group:
                        f["artist"] = named[0]
            aa = Counter(f["albumartist"] for f in group if f["albumartist"])
            artists = Counter(f["artist"] for f in group if f["artist"])
            if aa:
                release_artist = aa.most_common(1)[0][0]
            elif len(artists) > 2:
                release_artist = VARIOUS
            elif artists:
                release_artist = artists.most_common(1)[0][0]
            else:
                release_artist = folder_artist or _folder_album_name(folder)
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
    title = nfc(f["title"].strip())
    same = session.exec(select(Recording).where(Recording.artist_id == artist.id, Recording.title == title)).all()
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
            old_rec = session.get(Recording, f["old"]) if f["old"] else None
            if old_rec is not None and (old_rec.external_refs or {}).get("manual"):
                stats["manual"] += 1  # ručně opravené (třeba Once) -- nepřepisovat
                continue
            release_artist = find_or_create_artist(session, f["release_artist"], allow_own=True)
            release = find_or_create_release(session, release_artist, f["release"])
            artist = find_or_create_artist(session, f["artist"], allow_own=True)
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


_COMPILATION = re.compile(
    r"best of|greatest|very best|collection|hits|anthology|výběr|to nejlepší|\b(19|20)\d{2}\s*-\s*(19|20)\d{2}\b",
    re.IGNORECASE,
)
_GENERIC = {"folk", "dope mix", "local-music", "unknown album", "mp"}


def _is_compilation(release_title: str, release_artist: str, track_artists: int) -> bool:
    return (
        release_artist == VARIOUS
        or track_artists > 2
        or bool(_COMPILATION.search(release_title))
        or _norm(release_title) in _GENERIC
    )


def compilations_to_playlists() -> list[str]:
    """Výběry, soundtracky a mixy nejsou alba: z každé takové "složky-alba"
    vlastní playlist (pod jejím názvem), skladby pak album nemají."""
    from app.auth import ADMIN_ID
    from app.models import Artist, Playlist, PlaylistKind, Release

    made = []
    with Session(engine) as session:
        assets = session.exec(select(MediaAsset).where(MediaAsset.source_provider == "local")).all()
        by_release: dict[str, list[tuple[Recording, str]]] = defaultdict(list)
        for asset in assets:
            rec = session.get(Recording, asset.recording_id)
            if rec is not None and rec.release_id:
                by_release[rec.release_id].append((rec, asset.storage_path or ""))
        for release_id, tracks in by_release.items():
            release = session.get(Release, release_id)
            if release is None:
                continue
            artist = session.get(Artist, release.artist_id)
            artist_name = artist.name if artist else ""
            if any(p in _norm(release.title) or p in _norm(artist_name) for p in PROTECTED):
                continue
            if not _is_compilation(release.title, artist_name, len({r.artist_id for r, _ in tracks})):
                continue
            # Výběr o jedné skladbě nestojí za vlastní playlist.
            loose = _norm(release.title) in {"local-music", "mp"} or len(tracks) == 1
            title = "Volné skladby" if loose else release.title
            playlist = session.exec(
                select(Playlist).where(
                    Playlist.owner_user_id == ADMIN_ID, Playlist.kind == PlaylistKind.USER, Playlist.title == title
                )
            ).first()
            if playlist is None:
                playlist = Playlist(
                    owner_user_id=ADMIN_ID, title=title, kind=PlaylistKind.USER, description="Z tvé hudby", source="own-music:legacy"
                )
                session.add(playlist)
                session.commit()
                session.refresh(playlist)
            existing = {i.recording_id for i in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all()}
            ordered = sorted(tracks, key=lambda t: (t[0].track_number or 999, t[1]))
            for pos, (rec, _path) in enumerate(ordered):
                if rec.id not in existing:
                    session.add(PlaylistItem(playlist_id=playlist.id, recording_id=rec.id, position=pos))
                rec.release_id = None
                session.add(rec)
            session.commit()
            if not session.exec(select(Recording).where(Recording.release_id == release_id)).first():
                session.delete(release)
                session.commit()
            made.append(f"{title} ({len(tracks)})")
    return made


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
        print("playlisty z výběrů:", compilations_to_playlists())


if __name__ == "__main__":
    main()
