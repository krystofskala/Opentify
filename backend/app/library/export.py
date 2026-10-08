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
            # Zástupná `own:` id (vlastní hudba) do exportu nepatří.
            "isrc": _real(rec.isrc),
            "spotifyId": _real((rec.external_refs or {}).get("spotifyId")),
            "deezerId": _real(rec.deezer_id),
            "appleId": _real((rec.external_refs or {}).get("appleMusicId")),
            "mbid": _real(rec.mbid),
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


def _spoken(session: Session, user_id: str) -> tuple[dict, str]:
    """Mluvené slovo do exportu (souhrn 8. 10. #16): moje knihy s pozicí,
    srdíčka, historie po dnech -> JSON; odebírané podcasty -> OPML (načte je
    každá podcastová appka)."""
    from xml.sax.saxutils import quoteattr

    from app.models import (
        PodcastShow, PodcastSubscription, SpokenBook, SpokenFavorite, SpokenListenDay, SpokenProgress,
    )

    progress = {p.book_id: p for p in session.exec(select(SpokenProgress).where(SpokenProgress.user_id == user_id)).all()}
    favs = session.exec(select(SpokenFavorite).where(SpokenFavorite.user_id == user_id)).all()
    fav_books = {f.ref for f in favs if f.kind == "book"}
    books = []
    for b in session.exec(select(SpokenBook)).all():
        p = progress.get(b.id)
        if p is None and b.id not in fav_books and b.requested_by_user_id != user_id:
            continue  # jen moje knihy (poslouchané, se srdíčkem, stažené mnou)
        books.append({
            "title": b.title, "author": b.author, "narrator": b.narrator, "kind": b.kind or "book",
            "series": b.series_name or None, "seriesNumber": b.series_number,
            "favorite": b.id in fav_books,
            "progress": None if p is None else {"positionMs": p.position_ms, "finished": p.finished,
                                                "updatedAt": p.updated_at.isoformat() if p.updated_at else None},
        })
    history = [
        {"day": r.day, "kind": r.kind, "ref": r.ref, "seconds": round(r.seconds or 0)}
        for r in session.exec(select(SpokenListenDay).where(SpokenListenDay.user_id == user_id).order_by(SpokenListenDay.day)).all()
    ]
    shows = [
        session.get(PodcastShow, s.show_id)
        for s in session.exec(select(PodcastSubscription).where(PodcastSubscription.user_id == user_id)).all()
    ]
    shows = [s for s in shows if s is not None]
    data = {
        "books": books,
        "favoritePeople": [{"name": f.name, "role": f.ref.split(":", 1)[0]} for f in favs if f.kind == "person"],
        "podcasts": [{"title": s.title, "author": s.author, "feedUrl": s.feed_url} for s in shows],
        "listeningByDay": history,
    }
    outlines = "\n".join(
        f'    <outline type="rss" text={quoteattr(s.title)} title={quoteattr(s.title)} xmlUrl={quoteattr(s.feed_url)}/>'
        for s in shows
    )
    opml = (
        '<?xml version="1.0" encoding="UTF-8"?>\n<opml version="2.0">\n'
        "  <head><title>Opentify – podcasty</title></head>\n"
        f"  <body>\n{outlines}\n  </body>\n</opml>\n"
    )
    return data, opml


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
        spoken, opml = _spoken(session, user_id)
        z.writestr("mluvene_slovo.json", json.dumps(spoken, ensure_ascii=False, indent=1))
        z.writestr("podcasty.opml", opml)
        z.writestr(
            "CTI_ME.txt",
            "Export z Opentify\n\n"
            "vse_pro_tunemymusic.csv  -- vsechny playlisty v jednom souboru pro TuneMyMusic\n"
            "                            (tunemymusic.com > Upload file). Kazdy playlist se\n"
            "                            vytvori pod svym jmenem.\n"
            "playlisty/*.csv          -- totez po jednotlivych playlistech\n"
            "historie_poslechu.csv    -- vsechny poslechy s casem\n"
            "opentify.json            -- uplna zaloha vseho\n"
            "mluvene_slovo.json       -- audioknihy (pozice, srdicka, rady), oblibeni autori,\n"
            "                            historie poslechu po dnech\n"
            "podcasty.opml            -- odebirane podcasty (nacte je kazda podcastova appka)\n",
        )
    return out.getvalue()


def _real(value: str | None) -> str:
    return "" if not value or value.startswith("own:") else value
