"""Boti, kteří z internetu (Funnel) zkoušejí neexistující adresy
(`/wp-login.php`, `/.env`...) -- jednou za čas souhrn na telefon.

Dva zdroje:
  - web (nginx): neexistující cesty z Funnelu zapisuje do `PROBE_LOG`
    (web/nginx.conf, sdílený svazek); odpověď se nemění,
  - API: požadavek z internetu, který nenašel žádnou cestu (404 bez routy).

Souhrn nejvýš jednou za hodinu a jen od `MIN_HITS` pokusů; tiché upozornění
(nízká priorita) -- informace, ne poplach.
"""

from __future__ import annotations

import asyncio
import logging
import os
import time
from collections import Counter

logger = logging.getLogger(__name__)

PROBE_LOG = os.environ.get("PROBE_LOG", "/data/probe/funnel-unknown.log")
EVERY_S = 3600
MIN_HITS = 3
MAX_LOG_BYTES = 1_000_000
MAX_READ_BYTES = 256_000  # na jeden tik -- zbytek příště (zahlcení nesmí nafouknout paměť)
MAX_IPS = 500
MAX_PATHS_PER_IP = 50

_pending: dict[str, Counter[str]] = {}
_offset: int | None = None
_last_sent = 0.0


# Běžné dotazy vyhledávačů a prohlížečů -- nejsou útok, do souhrnu nepatří
# (nginx je má filtrovat taky, tohle je pojistka: živě chodilo "robots.txt,
# sitemap.xml").
_BENIGN = ("/robots.txt", "/sitemap.xml", "/sitemap_index.xml", "/favicon.ico", "/ads.txt", "/humans.txt",
           "/apple-touch-icon", "/.well-known/", "/manifest.json", "/site.webmanifest", "/browserconfig.xml")


def record(ip: str, path: str) -> None:
    if (path or "").split("?")[0].lower().startswith(_BENIGN):
        return
    ip = ip or "?"
    if ip not in _pending and len(_pending) >= MAX_IPS:
        ip = "další"
    paths = _pending.setdefault(ip, Counter())
    key = path[:120]
    if key not in paths and len(paths) >= MAX_PATHS_PER_IP:
        key = "…další cesty"
    paths[key] += 1


def read_new_lines(path: str = PROBE_LOG) -> None:
    """Nové řádky z logu webu (čas, IP, metoda, cesta, prohlížeč -- oddělené
    tabulátorem). Při prvním čtení se přeskočí, co už v souboru bylo."""
    global _offset
    try:
        size = os.path.getsize(path)
    except OSError:
        return
    if _offset is None or size < _offset:
        _offset = size if _offset is None else 0
    if size == _offset:
        return
    with open(path, "rb") as f:
        f.seek(_offset)
        raw = f.read(MAX_READ_BYTES)
    if len(raw) == MAX_READ_BYTES and b"\n" in raw:
        raw = raw[: raw.rindex(b"\n") + 1]  # jen celé řádky, zbytek příští tik
    _offset += len(raw)
    for line in raw.decode("utf-8", errors="replace").splitlines():
        parts = line.split("\t")
        if len(parts) >= 4:
            ip = parts[1].split(",")[-1].strip()
            record(ip, parts[3])
    if size > MAX_LOG_BYTES:
        # Log nesmí růst donekonečna (nginx zapisuje v režimu append).
        try:
            with open(path, "w"):
                pass
            _offset = 0
        except OSError:
            pass


def summary() -> tuple[str, str] | None:
    hits = sum(sum(c.values()) for c in _pending.values())
    if hits < MIN_HITS:
        return None
    paths: Counter[str] = Counter()
    for c in _pending.values():
        paths.update(c)
    top = ", ".join(p for p, _ in paths.most_common(4))
    ips = len(_pending)
    return "🤖 Boti zkoušeli adresy", f"{hits}× z {ips} IP za poslední hodinu: {top}"


def flush(now: float | None = None) -> bool:
    global _last_sent
    now = time.monotonic() if now is None else now
    if now - _last_sent < EVERY_S:
        return False
    msg = summary()
    if msg is None:
        return False
    from app.notify import notify

    notify(msg[0], msg[1], priority=2)  # bez štítku "robot" -- ntfy ho kreslí jako druhého 🤖
    _pending.clear()
    _last_sent = now
    return True


async def probe_watch_loop(interval_s: float = 60.0) -> None:
    await asyncio.sleep(30)
    while True:
        try:
            await asyncio.to_thread(read_new_lines)
            flush()
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 -- smyčka nesmí umřít
            logger.exception("hlídání botů selhalo")
        await asyncio.sleep(interval_s)
