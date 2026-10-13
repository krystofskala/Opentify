"""Opakování skladby hned za sebou -- "líbí se", ale ne zkoušení s kapelou
(13. 10.: "opakování z oblíbenosti je real thing, opakování proto, že se
člověk musí naučit text, by vkus ovlivňovat nemělo").

Z poslechů (`Listen` -- appka i import historie; fronta z `context`):

- **zkušební playlist**: vlastní playlist / fronta, kde se skladby opakují
  hned za sebou nápadně často (u Táty "Koza Band": repertoár kapely). Jeho
  skladby se neberou jako chycené a opakování v něm nic neznamená;
- **smyčka**: vlastní playlist puštěný pořád dokola (zkoušení repertoáru),
  i bez opakování hned za sebou -- jeho skladby taky nejsou chycené;
- **dřina**: den, kdy jednu skladbu pustil hned znovu 3× a víc (učení textu,
  akordů) -- takový den se nepočítá;
- zbytek = **oblíbené opakování**; počítají se různé dny (ne kolikrát).

Ruční "Nepočítat do vkusu" v menu ⋯ (app/home/activation.taste_exclusions)
platí dál a má přednost.
"""

from __future__ import annotations

import time
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timedelta

from sqlmodel import Session, select

from app.db import engine
from app.models import Listen, PlaylistItem

REPEAT_GAP_S = 12 * 60  # poslech téže skladby skončil do 12 min po předchozím
PRACTICE_MIN_REPEATS = 10
PRACTICE_SHARE = 0.15  # opakování / přehrání v tom playlistu
DRILL_PER_DAY = 3
# Smyčka: vlastní playlist puštěný dokola (repertoár kapely, 13. 10.: Táta,
# "Koza Band" 128 poslechů za týden) -- za `LOOP_DAYS` aspoň `LOOP_PLAYS`
# poslechů a každá skladba v průměru `LOOP_PER_TRACK`×.
LOOP_DAYS = 60
LOOP_PLAYS = 40
LOOP_PER_TRACK = 4.0
PRACTICE_TRACK_SHARE = 0.5  # skladba hraná hlavně ze zkušebního playlistu
_CACHE_S = 6 * 3600
_cache: dict[str, tuple[float, "Repeats"]] = {}


@dataclass
class Repeats:
    loved_days: dict[str, list] = field(default_factory=dict)  # skladba -> dny oblíbeného opakování
    practice_tracks: set[str] = field(default_factory=set)
    practice_sources: set[str] = field(default_factory=set)

    def days(self, recording_id: str, since: datetime | None = None) -> int:
        ds = self.loved_days.get(recording_id, ())
        return sum(1 for d in ds if since is None or d >= since.date())


def _source(playlist_id: str | None, label: str | None) -> str | None:
    return f"playlist:{playlist_id}" if playlist_id else (f"label:{label}" if label else None)


def analyze(rows: list[tuple]) -> Repeats:
    """`rows`: (skladba, konec poslechu, playlist, název fronty) podle času."""
    plays: Counter = Counter()
    reps: Counter = Counter()
    events: list[tuple[str, object, str | None]] = []  # (skladba, den, zdroj) opakování
    track_plays: Counter = Counter()
    track_src: dict[str, Counter] = defaultdict(Counter)
    loop_plays: Counter = Counter()
    loop_tracks: dict[str, set] = defaultdict(set)
    recent = (rows[-1][1] - timedelta(days=LOOP_DAYS)) if rows else None
    prev = None
    for rid, started, playlist_id, label in rows:
        if playlist_id and recent is not None and started >= recent:
            loop_plays[playlist_id] += 1
            loop_tracks[playlist_id].add(rid)
        src = _source(playlist_id, label)
        if src:
            plays[src] += 1
        track_plays[rid] += 1
        if src:
            track_src[rid][src] += 1
        if prev and prev[0] == rid and (started - prev[1]).total_seconds() <= REPEAT_GAP_S:
            if src:
                reps[src] += 1
            events.append((rid, started.date(), src))
        prev = (rid, started)
    # "spotify:backbtn" apod. (import) není fronta -- zpět na skladbu je
    # naopak znak, že se líbí.
    practice = {
        s for s, n in reps.items()
        if n >= PRACTICE_MIN_REPEATS and n / max(1, plays[s]) >= PRACTICE_SHARE and not s.startswith("label:spotify:")
    }
    practice |= {
        f"playlist:{p}" for p, n in loop_plays.items()
        if n >= LOOP_PLAYS and n / max(1, len(loop_tracks[p])) >= LOOP_PER_TRACK
    }
    practice_tracks = {
        rid for rid, by in track_src.items()
        if sum(n for s, n in by.items() if s in practice) >= PRACTICE_TRACK_SHARE * track_plays[rid]
    }
    per_day = Counter((rid, day) for rid, day, _s in events)
    loved: dict[str, set] = defaultdict(set)
    for rid, day, src in events:
        if src in practice or rid in practice_tracks or per_day[(rid, day)] >= DRILL_PER_DAY:
            continue
        loved[rid].add(day)
    return Repeats({r: sorted(ds) for r, ds in loved.items()}, practice_tracks, practice)


def for_user(user_id: str) -> Repeats:
    hit = _cache.get(user_id)
    if hit and time.monotonic() - hit[0] < _CACHE_S:
        return hit[1]
    since = datetime.utcnow() - timedelta(days=5 * 365)
    with Session(engine) as session:
        raw = session.exec(
            select(Listen.recording_id, Listen.played_at, Listen.context)
            .where(Listen.user_id == user_id, Listen.played_at >= since)
            .order_by(Listen.played_at)  # type: ignore[arg-type]
        ).all()
    rows = []
    for rid, t, context in raw:
        path = (context or "").split("?")[0]
        playlist_id = path.split("/playlists/", 1)[1].split("/")[0] if "/playlists/" in path else None
        label = path if path and not playlist_id else None
        rows.append((rid, t, playlist_id, label))
    out = analyze(list(rows))
    loops = [s.split(":", 1)[1] for s in out.practice_sources if s.startswith("playlist:")]
    if loops:
        # Celý repertoár (i skladby slyšené dřív jinde) -- ne chycené, ne semínka.
        with Session(engine) as session:
            members = set(session.exec(select(PlaylistItem.recording_id).where(PlaylistItem.playlist_id.in_(loops))).all())  # type: ignore[attr-defined]
        out.practice_tracks |= members
        out.loved_days = {r: d for r, d in out.loved_days.items() if r not in members}
    _cache[user_id] = (time.monotonic(), out)
    return out
