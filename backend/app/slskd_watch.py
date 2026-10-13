"""Hlídá, jestli je slskd přihlášený do sítě Soulseek (13. 10.: od 14:17
visel ve stavu "Disconnecting" 6,5 hodiny, každé hledání skončilo za 0 s
bez výsledků, stahovalo se jen z YouTube a nikdo to nepoznal).

Worker se každou minutu zeptá (GET /api/v0/server). Odpojený déle než
2 minuty -> odpojit a znovu připojit (DELETE + PUT /api/v0/server) a
upozornit; když se nepřipojí ani tak, upozornění jednou za hodinu.
"""

from __future__ import annotations

import logging
import time

import httpx

logger = logging.getLogger(__name__)

GRACE_S = 120
_KEY = "slskd:offline-since"


async def check(r) -> str | None:
    """Vrátí stav, když slskd přihlášený není (None = v pořádku)."""
    from app.notify import notify
    from app.providers import SlskdProvider

    slskd = SlskdProvider()
    async with httpx.AsyncClient(base_url=slskd.base_url, headers=slskd._headers(), timeout=15) as c:
        try:
            server = (await c.get("/api/v0/server")).json() or {}
        except (httpx.HTTPError, ValueError):
            server = {"state": "nedostupný"}
        state = str(server.get("state") or "")
        if server.get("isLoggedIn") or "LoggedIn" in state:
            if await r.delete(_KEY):
                logger.info("slskd: zase přihlášený (%s)", state)
                notify("Soulseek zase běží", f"slskd je znovu přihlášený ({state}).", tags=["white_check_mark"])
            return None
        since = await r.get(_KEY)
        now = time.time()
        if since is None:
            await r.set(_KEY, now)
            return state
        if now - float(since) < GRACE_S:
            return state
        logger.warning("slskd: odpojený %d s (%s), připojuji znovu", now - float(since), state)
        try:
            await c.delete("/api/v0/server")
        except httpx.HTTPError:
            pass
        try:
            await c.put("/api/v0/server")
        except httpx.HTTPError as exc:
            logger.warning("slskd: připojení selhalo: %s", exc)
        notify(
            "Soulseek odpojený",
            f"slskd není přihlášený už {int((now - float(since)) / 60)} min ({state or 'neznámý stav'}). "
            "Zkouším ho znovu připojit; když to nepomůže, restart: docker compose restart slskd.",
            tags=["warning"],
            key="slskd-offline",
            every_s=3600,
        )
        return state
