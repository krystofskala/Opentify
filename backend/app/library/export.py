"""Export dat profilu do ZIPu -- oblíbené, vlastní playlisty, historie
poslechů, "Poslechnout později".

CSV ve formátu, který umí nahrát TuneMyMusic (a podobné převodníky do
Spotify, Apple Music, YouTube Music...): `Track name, Artist name, Album,
Playlist name, Type, ISRC`. ISRC zpřesní párování. Navíc `opentify.json`
se vším (i časy poslechů) jako úplná záloha.
"""

from __future__ import annotations

import csv
import io
import json
import re
import zipfile
from collections import Counter
from datetime import datetime

from sqlmodel import Session, select

from app.library.spotify_import import LIKED_SONGS_SOURCE
from app.models import Artist, Listen, ListenLater, Playlist, PlaylistItem, PlaylistKind, Recording, Release

# Stejné sloupce jako vlastní CSV export TuneMyMusic (ten určitě přijme);
# "Spotify - id" = přesná skladba bez hledání podle názvu.
TMM_HEADER = [
    "Track name", "Artist name", "Album", "Playlist name", "Type", "ISRC",
    "Spotify - id", "Deezer - id", "Apple Music - id",
]
TOP_TRACKS = 500


def _safe(name: str) -> str:
    return re.sub(r"[^\w\- ]+", "", name, flags=re.UNICODE).strip()[:60]


class _Lookup:
    """Názvy interpretů/alb s cache -- tisíce řádků bez tisíců dotazů."""

    def __init__(self, session: Session) -> None:
        self.session = session
        self._artists: dict[str, str] = {}
        self._releases: dict[str, str] = {}
        self._recordings: dict[str, Recording | None] = {}

    def preload(self, ids: list[str]) -> None:
        """Hromadně (po 900 -- limit SQLite) místo dotazu na každý řádek."""
        todo = [i for i in dict.fromkeys(ids) if i not in self._recordings]
        for n in range(0, len(todo), 900):
            chunk = todo[n : n + 900]
            for rec in self.session.exec(select(Recording).where(Recording.id.in_(chunk))).all():  # type: ignore[attr-defined]
                self._recordings[rec.id] = rec
        artist_ids = {r.artist_id for r in self._recordings.values() if r and r.artist_id} - set(self._artists)
        release_ids = {r.release_id for r in self._recordings.values() if r and r.release_id} - set(self._releases)
        for group in _chunks(list(artist_ids)):
            for a in self.session.exec(select(Artist).where(Artist.id.in_(group))).all():  # type: ignore[attr-defined]
                self._artists[a.id] = a.name
        for group in _chunks(list(release_ids)):
            for r in self.session.exec(select(Release).where(Release.id.in_(group))).all():  # type: ignore[attr-defined]
                self._releases[r.id] = r.title

    def recording(self, rid: str) -> Recording | None:
        if rid not in self._recordings:
            self._recordings[rid] = self.session.get(Recording, rid)
        return self._recordings[rid]

    def artist(self, aid: str | None) -> str:
        if not aid:
            return ""
        if aid not in self._artists:
            a = self.session.get(Artist, aid)
            self._artists[aid] = a.name if a else ""
        return self._artists[aid]

    def album(self, rid: str | None) -> str:
        if not rid:
            return ""
        if rid not in self._releases:
            r = self.session.get(Release, rid)
            self._releases[rid] = r.title if r else ""
        return self._releases[rid]

    def track(self, rid: str) -> dict | None:
        rec = self.recording(rid)
        if rec is None:
            return None
        return {
            "title": rec.title,
            "artist": self.artist(rec.artist_id),
            "album": self.album(rec.release_id),
            "isrc": rec.isrc or "",
            "spotifyId": (rec.external_refs or {}).get("spotifyId") or "",
            "deezerId": rec.deezer_id or "",
            "appleId": (rec.external_refs or {}).get("appleMusicId") or "",
            "mbid": rec.mbid or "",
            "recordingId": rec.id,
        }


def _chunks(items: list[str], size: int = 900) -> list[list[str]]:
    return [items[n : n + size] for n in range(0, len(items), size)]


def _tmm_rows(tracks: list[dict], playlist: str) -> list[list[str]]:
    return [
        [t["title"], t["artist"], t["album"], playlist, "Playlist", t["isrc"], t["spotifyId"], t["deezerId"], t["appleId"]]
        for t in tracks
    ]


def _csv(rows: list[list[str]], header: list[str]) -> bytes:
    buf = io.StringIO()
    writer = csv.writer(buf)
    writer.writerow(header)
    writer.writerows(rows)
    # BOM -- Excel pak správně ukáže diakritiku.
    return ("﻿" + buf.getvalue()).encode("utf-8")


def build_export(session: Session, user_id: str, profile_name: str) -> bytes:
    look = _Lookup(session)
    playlists: list[tuple[str, list[dict]]] = []

    def items(playlist_id: str) -> list[dict]:
        rows = session.exec(
            select(PlaylistItem).where(PlaylistItem.playlist_id == playlist_id).order_by(PlaylistItem.position)
        ).all()
        return [t for t in (look.track(r.recording_id) for r in rows) if t]

    liked = session.exec(
        select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
    ).first()
    if liked is not None:
        playlists.append(("Oblíbené skladby", items(liked.id)))
    own = session.exec(
        select(Playlist)
        .where(Playlist.owner_user_id == user_id, Playlist.kind == PlaylistKind.USER)
        .order_by(Playlist.title)
    ).all()
    for p in own:
        if p.source == LIKED_SONGS_SOURCE:
            continue
        playlists.append((p.title, items(p.id)))

    listens = session.exec(select(Listen).where(Listen.user_id == user_id).order_by(Listen.played_at)).all()
    look.preload([listen.recording_id for listen in listens])
    history = []
    for listen in listens:
        t = look.track(listen.recording_id)
        if t:
            history.append({**t, "playedAt": listen.played_at.isoformat(), "msPlayed": listen.duration_played_ms})
    plays = Counter(h["recordingId"] for h in history)
    top = [t for t in (look.track(rid) for rid, _ in plays.most_common(TOP_TRACKS)) if t]
    if top:
        playlists.append(("Moje nejposlouchanější", top))

    later_rows = session.exec(
        select(ListenLater).where(ListenLater.user_id == user_id, ListenLater.kind == "track")
    ).all()
    later = [t for t in (look.track(r.target_id) for r in later_rows if r.listened_at is None) if t]
    if later:
        playlists.append(("Na později", later))

    out = io.BytesIO()
    with zipfile.ZipFile(out, "w", zipfile.ZIP_DEFLATED) as z:
        all_rows: list[list[str]] = []
        used: set[str] = set()
        for n, (title, tracks) in enumerate(playlists, 1):
            rows = _tmm_rows(tracks, title)
            all_rows.extend(rows)
            # Pořadí v názvu -- stejně pojmenované playlisty se nepřepíšou
            # a názvy jen z emoji nezmizí.
            name = f"{n:02d} {_safe(title)}"
            while name in used:
                name += "_"
            used.add(name)
            z.writestr(f"playlisty/{name}.csv", _csv(rows, TMM_HEADER))
        z.writestr("vse_pro_tunemymusic.csv", _csv(all_rows, TMM_HEADER))
        z.writestr(
            "historie_poslechu.csv",
            _csv(
                [[h["playedAt"], h["title"], h["artist"], h["album"], h["isrc"]] for h in history],
                ["Played at", "Track name", "Artist name", "Album", "ISRC"],
            ),
        )
        z.writestr(
            "opentify.json",
            json.dumps(
                {
                    "profile": profile_name,
                    "exportedAt": datetime.now().isoformat(timespec="seconds"),
                    "playlists": [{"title": t, "tracks": tr} for t, tr in playlists],
                    "listens": history,
                },
                ensure_ascii=False,
                indent=1,
            ),
        )
        z.writestr(
            "CTI_ME.txt",
            "Export z Opentify\n\n"
            "vse_pro_tunemymusic.csv  -- vsechny playlisty v jednom souboru pro TuneMyMusic\n"
            "                            (tunemymusic.com > Upload file). Kazdy playlist se\n"
            "                            vytvori pod svym jmenem.\n"
            "playlisty/*.csv          -- totez po jednotlivych playlistech\n"
            "historie_poslechu.csv    -- vsechny poslechy s casem\n"
            "opentify.json            -- uplna zaloha vseho\n",
        )
    return out.getvalue()
