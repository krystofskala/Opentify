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

    def update(self, user_id: str, device_key: str, state: dict[str, Any]) -> None:
        now = time.time()
        np = state.get("nowPlaying") or {}
        rid = np.get("recordingId") if isinstance(np, dict) else None
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
            self._finish(key)
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

    def _finish(self, key: tuple[str, str]) -> None:
        s = self._sessions.pop(key, None)
        if s is None:
            return
        duration = (s.duration_ms or 0) / 1000
        if duration and duration < 30:
            return
        threshold = min(duration / 2, 240) if duration else 240
        if s.played_s < threshold:
            return
        played_at = datetime.fromtimestamp(s.started_wall, tz=timezone.utc)
        try:
            asyncio.get_running_loop().create_task(
                asyncio.to_thread(_record, s.user_id, s.recording_id, played_at, int(s.played_s * 1000), s.source)
            )
        except RuntimeError:
            _record(s.user_id, s.recording_id, played_at, int(s.played_s * 1000), s.source)

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


def _record(user_id: str, recording_id: str, played_at: datetime, played_ms: int, source: str | None) -> None:
    from app.listens import record_listen

    try:
        listen_id = record_listen(user_id, recording_id, played_at=played_at, duration_played_ms=played_ms, source=source)
        if listen_id:
            logger.info("connect %s: poslech zapsán serverem %s (%d s)", user_id[:8], recording_id[:8], played_ms // 1000)
    except Exception:  # noqa: BLE001 -- záloha nesmí shodit Connect
        logger.exception("záložní poslech se nepodařilo zapsat")


tracker = ConnectListens()
