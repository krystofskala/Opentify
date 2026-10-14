"""Hlídač zastavení API zapíše zastavení nad limit (14. 10.)."""
import asyncio
import logging
import time

from app import loop_watch


def test_zastaveni_se_zapise(caplog, monkeypatch):
    monkeypatch.setattr(loop_watch, "LIMIT_S", 0.3)
    monkeypatch.setattr(loop_watch, "QUIET_S", 0.0)

    async def main():
        loop_watch.start()
        await asyncio.sleep(0.3)
        time.sleep(1.0)  # zablokovat smyčku
        await asyncio.sleep(0.8)

    with caplog.at_level(logging.WARNING, logger="app.loop_watch"):
        asyncio.run(main())
    text = caplog.text
    assert "API stojí už" in text and "time.sleep" in text
    assert "API stálo" in text
