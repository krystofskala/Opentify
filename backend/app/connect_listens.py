"""Záložní zapisování poslechů ze stavu Opentify Connect.

Zařízení posílá serveru stav přehrávání (`device.state`: skladba, hraje,
pozice, délka) při každé změně a za přehrávání každých ~15 s. Z toho server
pozná, že skladba opravdu hrála, i když appka poslech sama nenahlásí -- starší
iOS build ho na zamčeném telefonu nebo bez signálu ztrácel (živě: táta na
cestě, poslechy chyběly a doporučení se neučila).

Pravidlo stejné jako v appce: odehráno aspoň půl skladby nebo 4 minuty,
skladby kratší než 30 s ne. Odehraný čas = skutečně uplynulý čas přehrávání,
ale nejvýš o kolik se posunula pozice (+2 s) -- přetočení dopředu se nepočítá.
Když appka poslech nahlásila sama, server ho nezdvojí (`record_listen` je
idempotentní v okně kolem začátku).
"""

from __future__ import annotations

import asyncio
import logging
import time
from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Any

logger = logging.getLogger("uvicorn.error.connect")

# Bez nového stavu tak dlouho = zařízení zmizelo (zabitá appka, bez signálu).
STALE_SECONDS = 10 * 60


@dataclass
class _Session:
    user_id: str
    recording_id: str
    started_wall: float
    last_wall: float
    last_pos_ms: int | None
    playing: bool
    duration_ms: int | None
    source: str | None
    played_s: float = 0.0


class ConnectListens:
    def __init__(self) -> None:
        # (profil, zařízení) -> rozehraná skladba
        self._sessions: dict[tuple[str, str], _Session] = {}
        self._sweeper: asyncio.Task | None = None
        # (profil, zařízení) -> časy posledních přeskočení (proklikávání)
        self._skips: dict[tuple[str, str], list[float]] = {}

    def update(self, user_id: str, device_key: str, state: dict[str, Any]) -> None:
        now = time.time()
        np = state.get("nowPlaying") or {}
        rid = np.get("recordingId") if isinstance(np, dict) else None
        # Mluvené slovo (audiokniha "sp:", podcast "pc:") není hudební poslech.
        if isinstance(rid, str) and rid.startswith(("sp:", "pc:")):
            rid = None
        pos = state.get("positionMs")
        pos = int(pos) if isinstance(pos, (int, float)) else None
        playing = bool(state.get("isPlaying"))
        key = (user_id, device_key)
        cur = self._sessions.get(key)

        # Tatáž skladba znovu od začátku (opakování) = nový poslech.
        restarted = (
            cur is not None and cur.recording_id == rid and pos is not None and cur.last_pos_ms is not None
            and pos < 5000 and cur.last_pos_ms - pos > 15000
        )
        if cur is not None and (cur.recording_id != rid or restarted):
            if cur.playing:
                # Kousek od posledního stavu do konce (stav chodí po ~15 s).
                cur.played_s += min(max(0.0, now - cur.last_wall), 16.0)
            # Přechod na JINOU skladbu po pár vteřinách = přeskočení (ne
            # opakování téže, ne zastavení / zmizení zařízení).
            self._finish(key, switched=bool(rid) and cur.recording_id != rid)
            cur = None
        if not rid:
            return
        if cur is None:
            self._sessions[key] = _Session(
                user_id=user_id, recording_id=str(rid), started_wall=now - (pos or 0) / 1000 if playing else now,
                last_wall=now, last_pos_ms=pos, playing=playing,
                duration_ms=state.get("durationMs") if isinstance(state.get("durationMs"), int) else None,
                source=state.get("sourceLabel") if isinstance(state.get("sourceLabel"), str) else None,
            )
            return
        if cur.playing:
            elapsed = max(0.0, now - cur.last_wall)
            if pos is not None and cur.last_pos_ms is not None:
                moved = (pos - cur.last_pos_ms) / 1000
                cur.played_s += max(0.0, min(elapsed, moved + 2)) if moved >= 0 else 0.0
            else:
                cur.played_s += elapsed
        cur.last_wall = now
        cur.last_pos_ms = pos if pos is not None else cur.last_pos_ms
        cur.playing = playing
        if isinstance(state.get("durationMs"), int):
            cur.duration_ms = state["durationMs"]
        self._ensure_sweeper()

    def _finish(self, key: tuple[str, str], switched: bool = False) -> None:
        s = self._sessions.pop(key, None)
        if s is None:
            return
        duration = (s.duration_ms or 0) / 1000
        if duration and duration < 30:
            return
        skipped = switched and s.played_s < min(30.0, (duration or 120) / 4)
        if duration and s.played_s >= duration * 0.9:
            reason = "completed"
        elif skipped:
            reason = "skipped"
        elif switched:
            reason = "next"
        else:
            reason = "stopped"
        # Proklikávání (3+ přeskočení během minuty) = hledání, co pustit, ne
        # "tohle nechci" -- do přeskakování se nepočítá.
        browsing = False
        if skipped:
            now = time.time()
            recent = [t for t in self._skips.get(key, []) if now - t < 60] + [now]
            self._skips[key] = recent
            browsing = len(recent) >= 3
        self._run(
            _play_event, s.user_id, key[1], s.recording_id, s.started_wall, s.played_s, s.duration_ms, reason, s.source,
            skipped and not browsing,
        )
        threshold = min(duration / 2, 240) if duration else 240
        if s.played_s < threshold:
            return
        played_at = datetime.fromtimestamp(s.started_wall, tz=timezone.utc)
        self._run(_record, s.user_id, s.recording_id, played_at, int(s.played_s * 1000), s.source)

    @staticmethod
    def _run(fn, *args) -> None:
        try:
            asyncio.get_running_loop().create_task(asyncio.to_thread(fn, *args))
        except RuntimeError:
            fn(*args)

    def _ensure_sweeper(self) -> None:
        if self._sweeper is not None and not self._sweeper.done():
            return
        try:
            self._sweeper = asyncio.get_running_loop().create_task(self._sweep())
        except RuntimeError:
            pass

    async def _sweep(self) -> None:
        while self._sessions:
            await asyncio.sleep(60)
            cutoff = time.time() - STALE_SECONDS
            for key, s in list(self._sessions.items()):
                if s.last_wall < cutoff:
                    # Hrálo až do posledního stavu -- dopočítat k poslední zprávě.
                    self._finish(key)


# Název fronty Pusť teď v klientu (client/lib/state/auto_continue.dart).
PLAY_NOW_LABEL = "Pusť teď"


def _record(user_id: str, recording_id: str, played_at: datetime, played_ms: int, source: str | None) -> None:
    from app.listens import record_listen

    try:
        listen_id = record_listen(user_id, recording_id, played_at=played_at, duration_played_ms=played_ms, source=source)
        if listen_id:
            logger.info("connect %s: poslech zapsán serverem %s (%d s)", user_id[:8], recording_id[:8], played_ms // 1000)
    except Exception:  # noqa: BLE001 -- záloha nesmí shodit Connect
        logger.exception("záložní poslech se nepodařilo zapsat")


def _play_event(
    user_id: str, device_key: str, recording_id: str, started_wall: float, played_s: float,
    duration_ms: int | None, reason: str, source: str | None, count_skip: bool = False,
) -> None:
    """Zapsat přehrání (PlayEvent). Fronta se pozná podle názvu: playlist
    profilu se stejným názvem -> jeho id; generovaný (mix) = algoritmický.

    `count_skip`: přeskočení se do SkipStreak počítá JEN v mixu / rádiu --
    ve vlastním playlistu nebo albu je přeskočení výběr, ne "nelíbí se"."""
    algorithmic = False
    from sqlmodel import Session, select

    from app.db import engine
    from app.models import GLOBAL_PLAYLIST_OWNER, PlayEvent, Playlist
    from app.utils import utcnow

    try:
        with Session(engine) as session:
            playlist = None
            if source:
                playlist = session.exec(
                    select(Playlist).where(
                        Playlist.title == source,
                        Playlist.owner_user_id.in_([user_id, GLOBAL_PLAYLIST_OWNER]),  # type: ignore[attr-defined]
                    )
                ).first()
            from app.home.activation import ALGO_KINDS

            # Stejná definice jako u poslechů (app/home/activation.py): mixy,
            # rádio, doporučení, žebříčky, žánrové a redakční playlisty.
            algorithmic = bool(
                playlist and getattr(playlist.kind, "value", playlist.kind) in ALGO_KINDS
            ) or source == PLAY_NOW_LABEL or (source or "").startswith("Rádio · ")
            # Skladba z várky Pusť teď / nekonečného hraní (app/rec_log.py) --
            # i když fronta nese název alba či playlistu, ze kterého se navázalo.
            from app import rec_log

            # Napojit na várku: v algoritmické frontě vždy (12 h), jinak (fronta
            # nese název alba -- nekonečné hraní) jen do 3 h, ať se vlastní
            # album se skladbou z dávné várky nebere jako algoritmus.
            offered = (
                rec_log.match(session, user_id, recording_id)
                if algorithmic
                else rec_log.match(session, user_id, recording_id, hours=3) if not playlist else None
            )
            if offered is not None:
                algorithmic = True
            session.add(
                PlayEvent(
                    user_id=user_id,
                    recording_id=recording_id,
                    started_at=datetime.fromtimestamp(started_wall, tz=timezone.utc),
                    ended_at=utcnow(),
                    played_ms=int(played_s * 1000),
                    duration_ms=duration_ms,
                    end_reason=reason,
                    source_label=source,
                    playlist_id=playlist.id if playlist else None,
                    algorithmic=algorithmic,
                    device_key=device_key,
                    rec_batch_id=offered.batch_id if offered is not None else None,
                    rec_slot=offered.slot if offered is not None else None,
                )
            )
            session.commit()
    except Exception:  # noqa: BLE001 -- měření nesmí shodit Connect
        logger.exception("přehrání se nepodařilo zapsat")
    if count_skip and algorithmic:
        _skip(user_id, recording_id)


def _skip(user_id: str, recording_id: str) -> None:
    from sqlmodel import Session

    from app.db import engine
    from app.models import SkipStreak
    from app.utils import utcnow

    try:
        with Session(engine) as session:
            row = session.get(SkipStreak, (user_id, recording_id)) or SkipStreak(user_id=user_id, recording_id=recording_id)
            row.streak += 1
            row.updated_at = utcnow()
            session.add(row)
            session.commit()
    except Exception:  # noqa: BLE001
        logger.exception("přeskočení se nepodařilo zapsat")


tracker = ConnectListens()
