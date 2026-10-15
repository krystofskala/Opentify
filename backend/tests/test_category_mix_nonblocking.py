"""Mix kategorie nesmí zastavit API: generátory běží v procesu API a čekání
na SQLite v `load_snapshot` stálo celé API 3,3 s (hlídač, 15. 10.)."""
import asyncio
import time
from types import SimpleNamespace

from app import browse
from app.home import category_mixes as cm
from app.home import generators as g
from app.home import personal_mixes as pm


def test_cteni_stavu_mixu_neblokuje_smycku(monkeypatch):
    day = f"{pm._day_key()}:{cm._VERSION}"

    def slow_snapshot(_session, _key):
        time.sleep(0.3)  # pomalé čtení z DB
        return SimpleNamespace(payload={"stamp": day, "playlistId": "mix-1"})

    monkeypatch.setattr(g, "load_snapshot", slow_snapshot)
    category = browse.get_category("sleep")
    ticks = 0

    async def ticker(stop: asyncio.Event):
        nonlocal ticks
        while not stop.is_set():
            ticks += 1
            await asyncio.sleep(0.01)

    async def run():
        stop = asyncio.Event()
        t = asyncio.create_task(ticker(stop))
        result = await cm.build_category_mix(category)
        stop.set()
        await t
        return result

    assert asyncio.run(run()) == "mix-1"
    # Během 0,3 s čtení smyčka dál běžela (blokující čtení by dalo ~1 tik).
    assert ticks >= 10
