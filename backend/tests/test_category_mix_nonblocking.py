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


def test_vyber_zanru_na_domu_neblokuje_smycku(monkeypatch):
    """Totéž pro generátor „Tvoje žánry“ (čtení výběru, když je dnešní)."""
    day = f"{pm._day_key()}:{cm._VERSION}"

    def slow_snapshot(_session, _key):
        time.sleep(0.3)
        return SimpleNamespace(payload={"stamp": day, "picks": ["rock", "folk"]})

    monkeypatch.setattr(g, "load_snapshot", slow_snapshot)
    ticks = 0

    async def ticker(stop: asyncio.Event):
        nonlocal ticks
        while not stop.is_set():
            ticks += 1
            await asyncio.sleep(0.01)

    async def run():
        stop = asyncio.Event()
        t = asyncio.create_task(ticker(stop))
        result = await cm.build_home_category_mixes()
        stop.set()
        await t
        return result

    assert asyncio.run(run()) == 2
    assert ticks >= 10


def test_hlidac_pozna_kod_appky():
    """Výpis hlídače bere jen rámce z balíčku app (ne .venv ani /app2)."""
    import os

    from app import loop_watch

    here = os.path.abspath(loop_watch.__file__)
    assert here.startswith(loop_watch._APP_DIR)
    assert not os.path.join(os.path.dirname(loop_watch._APP_DIR.rstrip(os.sep)), ".venv", "x.py").startswith(loop_watch._APP_DIR)
    assert not (loop_watch._APP_DIR.rstrip(os.sep) + "2" + os.sep + "x.py").startswith(loop_watch._APP_DIR)
