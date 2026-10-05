"""Objevy, které tě chytly (Profil › Objevy).

Objev = skladba, kterou profil slyšel poprvé (poslech >= 30 s; verze téže
písně se berou jako jedna -- `activation.track_key`). Chytla = do 30 dní
od prvního poslechu ji pustil ještě aspoň ve 2 dalších dnech, nebo si ji
dal do Oblíbených / svého playlistu. Mladší 30 dní a zatím nechycená =
"ještě se uvidí".

Zdroj objevu podle toho, odkud hrál první poslech (`Listen.context` --
cesta v appce, `Listen.source` -- název fronty, importy podle platformy).
Importované historie se počítají stejně jako poslechy v appce.

Hromadně přidané skladby (import Oblíbených ze Spotify -- datum přidání je
datum importu) se jako uložení nepočítají.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from datetime import datetime, timedelta
from typing import Any

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, Listen, Playlist, PlaylistItem, PlaylistKind, Recording
from app.utils import utcnow

MIN_MS = 30_000
CATCH_DAYS = 30
OTHER_DAYS = 2
BURST = 20  # tolik uložení během jedné minuty = hromadný import, ne volba

IMPORTS = {
    "spotify-history": "Spotify (import)",
    "applemusic-history": "Apple Music (import)",
    "ytmusic-history": "YouTube Music (import)",
}


def category(context: str | None, source: str | None, playlist: Playlist | None) -> str:
    if source in IMPORTS:
        return IMPORTS[source]
    if source == "Pusť teď":
        return "Pusť teď"
    ctx = context or ""
    if ctx.startswith("/playlists/"):
        src = (playlist.source or "") if playlist else ""
        if playlist is None:
            return "Playlisty"
        if src.startswith("personal:daily-mix"):
            return "Denní mixy"
        if src.startswith("personal:discover-weekly"):
            return "Objevy týdne"
        if playlist.kind == PlaylistKind.RADIO:
            return "Rádio"
        if playlist.kind in (PlaylistKind.GENRE, PlaylistKind.EDITORIAL, PlaylistKind.CHART):
            return "Žánry a žebříčky"
        if playlist.kind == PlaylistKind.USER:
            return "Tvoje playlisty"
        return "Tvoje mixy"
    if ctx.startswith("/releases/"):
        return "Alba"
    if ctx.startswith("/artists/"):
        return "Stránky interpretů"
    if ctx.startswith("/search") or source == "Výsledky hledání":
        return "Hledání"
    if ctx.startswith("/shazam") or source == "Open Shazam":
        return "Shazam"
    if (source or "").startswith("Rádio"):
        return "Rádio"
    if ctx.startswith("/library"):
        return "Knihovna"
    return "Domů a ostatní"


def _saves(session: Session, user_id: str) -> dict[str, datetime]:
    """recording -> kdy si ho profil sám uložil (Oblíbené, vlastní playlist)."""
    rows = session.exec(
        select(PlaylistItem.recording_id, PlaylistItem.added_at)
        .join(Playlist, Playlist.id == PlaylistItem.playlist_id)
        .where(Playlist.owner_user_id == user_id, Playlist.kind == PlaylistKind.USER)
    ).all()
    per_minute = Counter(at.replace(second=0, microsecond=0) for _rid, at in rows if at)
    out: dict[str, datetime] = {}
    for rid, at in rows:
        if at is None or per_minute[at.replace(second=0, microsecond=0)] >= BURST:
            continue
        if rid not in out or at < out[rid]:
            out[rid] = at
    return out


def report(user_id: str, days: int = 180, now: datetime | None = None) -> dict[str, Any]:
    from app.home.activation import track_key

    now = (now or utcnow()).replace(tzinfo=None)  # časy v DB jsou naivní UTC
    since = now - timedelta(days=days)
    with Session(engine) as session:
        rows = session.exec(
            select(Listen.recording_id, Listen.played_at, Listen.context, Listen.source, Recording.title, Artist.name)
            .join(Recording, Recording.id == Listen.recording_id)
            .join(Artist, Artist.id == Recording.artist_id, isouter=True)
            .where(Listen.user_id == user_id)
            .where((Listen.duration_played_ms.is_(None)) | (Listen.duration_played_ms >= MIN_MS))  # type: ignore[union-attr]
            .order_by(Listen.played_at)
        ).all()
        saves = _saves(session, user_id)
        playlist_ids = {
            ctx.split("/")[2].split("?")[0] for _r, _t, ctx, _s, _ti, _a in rows if ctx and ctx.startswith("/playlists/") and ctx.count("/") >= 2
        }
        playlists = {p.id: p for p in session.exec(select(Playlist).where(Playlist.id.in_(playlist_ids))).all()} if playlist_ids else {}  # type: ignore[union-attr]

    first: dict[str, tuple[str, datetime, str]] = {}  # klíč -> (recording, kdy, zdroj)
    days_of: dict[str, set] = defaultdict(set)
    ids_of: dict[str, set[str]] = defaultdict(set)
    for rid, at, ctx, src, title, artist in rows:
        key = track_key(artist or "", title or "")
        ids_of[key].add(rid)
        if key not in first:
            pid = ctx.split("/")[2].split("?")[0] if ctx and ctx.startswith("/playlists/") and ctx.count("/") >= 2 else None
            first[key] = (rid, at, category(ctx, src, playlists.get(pid) if pid else None))
        if at >= first[key][1]:
            days_of[key].add(at.date())

    per_source: dict[str, Counter] = defaultdict(Counter)
    weeks: dict[str, Counter] = defaultdict(Counter)
    caught_recent: list[tuple[datetime, str, str]] = []
    for key, (rid, at, src) in first.items():
        if at < since:
            continue
        window_end = at + timedelta(days=CATCH_DAYS)
        other_days = {d for d in days_of[key] if at.date() < d <= window_end.date()}
        saved = any(
            (s := saves.get(r)) is not None and at - timedelta(days=1) <= s <= window_end for r in ids_of[key]
        )
        caught = len(other_days) >= OTHER_DAYS or saved
        state = "caught" if caught else ("pending" if now < window_end else "missed")
        per_source[src][state] += 1
        week = f"{at.isocalendar()[0]}-W{at.isocalendar()[1]:02d}"
        weeks[week]["new"] += 1
        weeks[week][state] += 1
        if caught:
            caught_recent.append((at, rid, src))

    sources = [
        {
            "source": src,
            "new": sum(c.values()),
            "caught": c["caught"],
            "pending": c["pending"],
        }
        for src, c in per_source.items()
    ]
    # Nejvíc chycených nahoře, pak podle počtu nových.
    sources.sort(key=lambda s: (-s["caught"], -s["new"]))
    caught_recent.sort(reverse=True)
    week_keys = sorted(weeks)[-12:]
    return {
        "days": days,
        "catchDays": CATCH_DAYS,
        "total": {
            "new": sum(s["new"] for s in sources),
            "caught": sum(s["caught"] for s in sources),
            "pending": sum(s["pending"] for s in sources),
        },
        "sources": sources,
        "weeks": [{"week": w, "new": weeks[w]["new"], "caught": weeks[w]["caught"]} for w in week_keys],
        "recentCaught": [{"recordingId": rid, "source": src, "firstPlayedAt": at.isoformat()} for at, rid, src in caught_recent[:30]],
    }
