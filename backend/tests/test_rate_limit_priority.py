"""Pozadí ustoupí: dotaz z úlohy na pozadí počká, dokud fronta limitu
nezvolní pod půl sekundy; popředí čeká jen na svůj slot."""
from __future__ import annotations

import asyncio
import time

from app.catalog import rate_limit as rl


def test_background_waits_for_quiet_queue(monkeypatch):
    lim = rl.AsyncRateLimiter(1.0)  # bez Redisu = místní limit
    log: list[tuple[str, float]] = []

    async def fg(name):
        await lim.wait()
        log.append((name, time.monotonic()))

    async def bg():
        rl.mark_background()
        await lim.wait()
        log.append(("bg", time.monotonic()))

    async def run():
        start = time.monotonic()
        lim._last_call = start + 1.5  # fronta: 2,5 s dopředu zabraná
        await asyncio.gather(bg(), fg("fg"))
        return start

    start = asyncio.run(run())
    order = [n for n, _t in log]
    assert order == ["fg", "bg"]  # popředí první, i když pozadí začalo dřív
    assert rl._background.get() is False  # značka jen v úloze pozadí


def test_foreground_not_delayed_when_quiet():
    lim = rl.AsyncRateLimiter(0.01)

    async def run():
        t = time.monotonic()
        await lim.wait()
        return time.monotonic() - t

    assert asyncio.run(run()) < 0.2
