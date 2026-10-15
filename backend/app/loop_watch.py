"""Hlídač zastavení API (14. 10. 2026).

Mix nálady blokoval celé API 11 s a nikdo to nevěděl – v tu chvíli se nespustila
žádná skladba. Úloha v asyncio každých 0,25 s potvrdí, že smyčka žije; vlákno
vedle kontroluje, kdy naposledy. Když smyčka stojí déle než `LIMIT_S`, vlákno
zapíše do logu, co právě běží (zásobník hlavního vlákna), a po uvolnění, jak
dlouho to trvalo. Nic nemění, jen loguje (nejvýš jednou za `QUIET_S`).
"""

from __future__ import annotations

import asyncio
import logging
import os
import sys
import threading
import time
import traceback

logger = logging.getLogger(__name__)

# Kód appky = balíček app (adresář tohoto souboru), s oddělovačem na konci,
# ať neprojde ani .venv vedle, ani /app2.
_APP_DIR = os.path.dirname(os.path.abspath(__file__)) + os.sep
LIMIT_S = 1.0
QUIET_S = 60.0
_beat = time.monotonic()


async def heartbeat() -> None:
    global _beat
    while True:
        _beat = time.monotonic()
        await asyncio.sleep(0.25)


def _watch(loop_thread_id: int) -> None:
    last_report = 0.0
    stuck_since: float | None = None
    while True:
        time.sleep(0.25)
        lag = time.monotonic() - _beat
        if lag > LIMIT_S and stuck_since is None:
            stuck_since = _beat
            now = time.monotonic()
            if now - last_report > QUIET_S:
                last_report = now
                frame = sys._current_frames().get(loop_thread_id)
                # Volající z kódu appky (kdo blokuje) + konec zásobníku (čím);
                # samotný konec ukazoval jen knihovnu SQLAlchemy (15. 10.).
                frames = traceback.extract_stack(frame) if frame else []
                ours = [f for f in frames if os.path.abspath(f.filename).startswith(_APP_DIR)]
                stack = "".join(traceback.format_list(ours[-8:])) + "  …\n" + "".join(traceback.format_list(frames[-4:])) if frames else "?"
                logger.warning("API stojí už %.1f s, právě běží:\n%s", lag, stack)
        elif lag <= LIMIT_S and stuck_since is not None:
            logger.warning("API stálo %.1f s", time.monotonic() - stuck_since)
            stuck_since = None


def start() -> None:
    """Zavolat ze spuštění API (uvnitř běžící smyčky)."""
    asyncio.get_running_loop().create_task(heartbeat())
    threading.Thread(target=_watch, args=(threading.get_ident(),), name="loop-watch", daemon=True).start()
