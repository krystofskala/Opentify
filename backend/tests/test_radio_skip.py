"""Přeskočení ve stejném rádio streamu (zamčený iPhone, 9. 10.)."""

import asyncio

from app import radio
from app.radio import RadioSession, Segment


def _session() -> RadioSession:
    s = RadioSession(id="ab" * 8, user_id="u", device_id="d", queue=["a", "b", "c"])
    s.timeline = [Segment("a", 0, 0.0, 0.0, duration_ms=180_000)]
    return s


def test_next_already_written_is_just_found():
    s = _session()
    s.timeline.append(Segment("b", 1, 180_000.0, 0.0))
    out = asyncio.run(radio.skip(s, 1, 170_000.0))
    assert out == (180_000.0, "b")
    assert s.skip_to is None  # výroba se nepřerušila
    assert s.skew_ms == 10_000.0


def test_skip_cuts_production_and_waits_for_target():
    s = _session()

    async def run():
        async def producer():
            while s.skip_to is None:
                await asyncio.sleep(0.01)
            target, s.skip_to = s.skip_to, None
            s.skip_cut_ms = 25_000.0
            s.timeline.append(Segment(s.queue[target], target, 25_000.0, 0.0))

        task = asyncio.create_task(producer())
        out = await radio.skip(s, 1, 5_000.0)
        await task
        return out

    assert asyncio.run(run()) == (25_000.0, "b")
    assert s.skew_ms == 20_000.0


def test_target_still_downloading_seeks_to_cut_point():
    s = _session()

    async def run():
        async def producer():
            while s.skip_to is None:
                await asyncio.sleep(0.01)
            s.skip_to = None
            s.skip_cut_ms = 25_000.0  # mezitím ticho, skladba se stahuje

        task = asyncio.create_task(producer())
        out = await radio.skip(s, 1, 5_000.0, wait_s=0.3)
        await task
        return out

    assert asyncio.run(run()) == (25_000.0, "b")


def test_no_previous_before_first_and_no_next_after_last():
    s = _session()
    assert asyncio.run(radio.skip(s, -1, 1_000.0)) is None
    s.queue = ["a"]
    assert asyncio.run(radio.skip(s, 1, 1_000.0)) is None
