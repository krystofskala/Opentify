"""Import rozšířené historie poslechů ze Spotify ("Extended streaming
history" -- `Streaming_History_Audio_*.json` v ZIPu) a z ní playlisty
"Tvoje top skladby <rok>".

Převezme se jen to, co appka potřebuje: čas, délka přehrání, interpret,
skladba, album a Spotify id skladby. IP adresa, zařízení, země a podobně
se zahodí hned při čtení.

Poslechy (aspoň 30 s, jako počítá Spotify) se uloží do `Listen` se
`source="spotify-history"` -- osobní mixy tak znají i roky poslechu na
Spotify. `lb_submitted_at` je vyplněné: na ListenBrainz se neposílají
(historii tam uživatel nahrál sám, vznikly by duplikáty). Opakovaný import
staré importované poslechy nahradí, nic se nezdvojí.

Spuštění: `python -m app.library.spotify_history <zip> [user_id]`.
"""

from __future__ import annotations

import io
import json
import logging
import sys
import zipfile
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any, Iterable

from sqlmodel import Session, delete, select

from app.db import engine
from app.home import generators as g
from app.library.matching import attach_release_if_missing, find_or_create_artist, find_or_create_recording, find_or_create_release
from app.models import Listen, PlaylistKind, Recording
from app.utils import utcnow

logger = logging.getLogger("uvicorn.error")

SOURCE = "spotify-history"
# Importované historie (ne poslechy v appce) -- "Pokračovat v poslechu" je vynechá.
IMPORTED_SOURCES = (SOURCE, "ytmusic-history", "applemusic-history")
MIN_PLAY_MS = 30_000
YEAR_TOP = 100
FIRST_YEAR = 2016  # starší roky uživatel nechtěl
MIN_YEAR_PLAYS = 200  # rok s pár poslechy playlist nedostane


def _year_source(year: int) -> str:
    return f"personal:year:{year}"


def read_zip(raw: bytes) -> list[dict[str, Any]]:
    """Minimální záznamy `{ts, ms, track, artist, album, spotify_id}`."""
    plays: list[dict[str, Any]] = []
    from app.uploads import check_zip

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        check_zip(zf)
        for info in zf.infolist():
            name = info.filename.rsplit("/", 1)[-1]
            if not (name.startswith("Streaming_History_Audio") and name.endswith(".json")):
                continue
            for row in json.loads(zf.read(info).decode("utf-8-sig")):
                track = row.get("master_metadata_track_name")
                artist = row.get("master_metadata_album_artist_name")
                if not track or not artist or not row.get("ts"):
                    continue  # podcasty, audioknihy
                uri = row.get("spotify_track_uri") or ""
                plays.append(
                    {
                        "ts": row["ts"],
                        "ms": int(row.get("ms_played") or 0),
                        "track": track,
                        "artist": artist,
                        "album": row.get("master_metadata_album_album_name"),
                        "spotify_id": uri.rsplit(":", 1)[-1] if uri.startswith("spotify:track:") else None,
                        # Jak přehrání skončilo -- pro měření přeskakování
                        # (PlayEvent). Zařízení/platforma se dál nečtou.
                        "reason_end": row.get("reason_end"),
                        "skipped": bool(row.get("skipped")),
                    }
                )
    return plays


def _parse_ts(value: str) -> datetime:
    return datetime.fromisoformat(value.replace("Z", "+00:00"))


def _resolve(session: Session, plays: Iterable[dict[str, Any]]) -> dict[tuple[str, str], str]:
    """(interpret, skladba) -> recording id; zakládá, co v katalogu chybí."""
    out: dict[tuple[str, str], str] = {}
    for play in plays:
        key = (play["artist"].strip().lower(), play["track"].strip().lower())
        if key in out:
            continue
        artist = find_or_create_artist(session, play["artist"])
        recording = find_or_create_recording(session, artist, play["track"])
        if play.get("album"):
            attach_release_if_missing(session, recording, find_or_create_release(session, artist, play["album"]))
        if play.get("spotify_id") and not (recording.external_refs or {}).get("spotifyId"):
            refs = dict(recording.external_refs or {})
            refs["spotifyId"] = play["spotify_id"]  # rovnou použitelné i pro sdílecí odkazy
            recording.external_refs = refs
            session.add(recording)
            session.commit()
        out[key] = recording.id
    return out


def import_history(user_id: str, plays: list[dict[str, Any]], source: str = SOURCE) -> dict[str, Any]:
    """`source`: spotify-history / ytmusic-history -- každá platforma má svoje
    poslechy, nový import nahradí jen ty z téže platformy (dohromady se pak
    sčítají ve Wrapped a mixech)."""
    counted = [p for p in plays if p["ms"] >= MIN_PLAY_MS]
    with Session(engine) as session:
        ids = _resolve(session, counted)
        session.exec(delete(Listen).where(Listen.user_id == user_id, Listen.source == source))
        now = utcnow()
        batch = 0
        from app.models import Recording

        lengths: dict[str, int | None] = {}
        for play in counted:
            rid = ids[(play["artist"].strip().lower(), play["track"].strip().lower())]
            ms = play["ms"]
            if play.get("assumed"):
                # YouTube Music délku poslechu nezná: délka skladby (je-li
                # známá) místo paušálních 3 minut -- Wrapped jinak nafukoval.
                if rid not in lengths:
                    rec = session.get(Recording, rid)
                    lengths[rid] = rec.duration_ms if rec else None
                ms = lengths[rid] or ms
            session.add(
                Listen(
                    user_id=user_id,
                    recording_id=rid,
                    played_at=_parse_ts(play["ts"]).replace(tzinfo=None),
                    duration_played_ms=ms,
                    source=source,
                    lb_submitted_at=now,
                )
            )
            batch += 1
            if batch % 5000 == 0:
                session.commit()
        session.commit()
    events = import_play_events(user_id, plays, ids, source)
    years = build_year_playlists(user_id)
    return {"plays": len(plays), "listens": len(counted), "tracks": len(ids), "years": years, "playEvents": events}


def _end_reason(play: dict[str, Any]) -> str | None:
    reason = play.get("reason_end")
    if reason is None and "skipped" not in play:
        return None  # zdroj to neví (YouTube Music)
    if play.get("skipped") or (reason == "fwdbtn" and play["ms"] < MIN_PLAY_MS):
        return "skipped"
    if reason == "trackdone":
        return "completed"
    if reason in ("fwdbtn", "clickrow", "backbtn", "playbtn"):
        return "next"
    return "stopped"


def import_play_events(
    user_id: str, plays: list[dict[str, Any]], ids: dict[tuple[str, str], str] | None = None, source: str = SOURCE
) -> int:
    """Přehrání z importu jako PlayEvent i s tím, jak skončila (přeskočení,
    dohrání). Jen skladby, které profil aspoň jednou opravdu poslouchal --
    kvůli pouhým přeskočením se katalog nerozšiřuje. Poslechy (`Listen`) se
    tím nemění; opakovaný import nahradí jen PlayEventy téhož zdroje."""
    from app.models import PlayEvent

    if ids is None:
        with Session(engine) as session:
            ids = _resolve(session, [p for p in plays if p["ms"] >= MIN_PLAY_MS])
    written = 0
    with Session(engine) as session:
        session.exec(delete(PlayEvent).where(PlayEvent.user_id == user_id, PlayEvent.origin == source))
        for play in plays:
            reason = _end_reason(play)
            rid = ids.get((play["artist"].strip().lower(), play["track"].strip().lower()))
            if reason is None or rid is None:
                continue
            ended = _parse_ts(play["ts"]).replace(tzinfo=None)  # Spotify ts = konec přehrání
            session.add(
                PlayEvent(
                    user_id=user_id,
                    recording_id=rid,
                    started_at=ended - timedelta(milliseconds=play["ms"]),
                    ended_at=ended,
                    played_ms=play["ms"],
                    end_reason=reason,
                    origin=source,
                )
            )
            written += 1
            if written % 5000 == 0:
                session.commit()
        session.commit()
    return written


def _playlist_owner() -> str:
    return g.home_user()


def build_year_playlists(user_id: str) -> dict[int, int]:
    """Top skladby každého uzavřeného roku ze VŠECH poslechů -- importovaná
    historie ze Spotify i poslechy v appce (počet přehrání, při shodě
    celkový čas). Běží denně jako generátor Domů, takže 1. ledna přibude
    playlist za právě skončený rok."""
    # Rok podle českého času -- poslech 31.12. ve 23:30 patří do toho roku
    # a playlist za rok přibude o půlnoci, ne v 1:00.
    from app.home.personal_mixes import _TZ, _aware

    counts: dict[int, Counter] = defaultdict(Counter)
    time_ms: dict[int, Counter] = defaultdict(Counter)
    total: Counter = Counter()
    last_year = _aware(utcnow()).astimezone(_TZ).year - 1  # rozběhnutý rok ještě ne
    with Session(engine) as session:
        rows = session.exec(
            select(Listen.recording_id, Listen.played_at, Listen.duration_played_ms).where(Listen.user_id == user_id)
        ).all()
    for recording_id, played_at, ms in rows:
        year = _aware(played_at).astimezone(_TZ).year
        if not FIRST_YEAR <= year <= last_year:
            continue
        counts[year][recording_id] += 1
        time_ms[year][recording_id] += ms or 0
        total[year] += 1

    built: dict[int, int] = {}
    for year in range(FIRST_YEAR, last_year + 1):
        if total[year] < MIN_YEAR_PLAYS:
            continue
        ranked = sorted(counts[year], key=lambda r: (-counts[year][r], -time_ms[year][r]))[:YEAR_TOP]
        hours = round(sum(time_ms[year].values()) / 3_600_000)
        with Session(engine) as session:
            top = session.get(Recording, ranked[0])
            from app.catalog.availability import resolve_artist_name

            top_line = f"{top.title} ({resolve_artist_name(session, top.artist_id)})" if top else None
        g._save_playlist(
            owner=_playlist_owner(),
            source=_year_source(year),
            title=f"Tvoje top skladby {year}",
            description=f"{total[year]:,} přehrání · {hours:,} h".replace(",", " ")
            + (f" · Nejvíc: {top_line}" if top_line else ""),
            kind=PlaylistKind.PERSONAL_MIX,
            section="years",
            recording_ids=ranked,
            cover_urls=g._covers_for(ranked),
            ttl=timedelta(days=3650),
        )
        built[year] = len(ranked)
    return built


def main() -> None:
    """`<zip> [user_id] [--events-only]` -- `--events-only` doplní jen
    PlayEventy (jak přehrání skončila) a poslechy nechá, jak jsou."""
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    path = args[0]
    user_id = args[1] if len(args) > 1 else g.HOME_USER_ID
    with open(path, "rb") as fh:
        plays = read_zip(fh.read())
    started = datetime.now(timezone.utc)
    if "--events-only" in sys.argv:
        result: dict[str, Any] = {"playEvents": import_play_events(user_id, plays)}
        print(json.dumps(result), "za", round((datetime.now(timezone.utc) - started).total_seconds()), "s")
        return
    g.set_home_user(user_id)  # roční playlisty patří tomu profilu
    result = import_history(user_id, plays)
    print(json.dumps(result, default=str), "za", round((datetime.now(timezone.utc) - started).total_seconds()), "s")


if __name__ == "__main__":
    main()
