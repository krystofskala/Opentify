"""Přidělený port z VPN (ProtonVPN v gluetunu) do slskd.

Soulseek posílá výsledky hledání i soubory tak, že se ostatní připojí na
náš port. Bez otevřeného portu (Mullvad) se k nám nedostanou ti, kdo jsou
sami za routerem -- chybí výsledky, padají stažení ("Failed to establish a
direct or indirect connection"). Proton port přidělí (docker-compose.
proton-slsk.yml), ale může se změnit a slskd si nastavení portu za běhu
pamatuje jen do restartu -- worker proto každou minutu porovná port
z gluetunu s tím, co má slskd, a případně ho nastaví (PATCH /api/v0/options,
bez nového přihlášení).

Vypnuté, dokud není `SLSK_GLUETUN_CONTROL_URL` (jen se zapnutým souborem).
"""

from __future__ import annotations

import logging
import os

import httpx

logger = logging.getLogger(__name__)


async def forwarded_port(url: str, key: str) -> int | None:
    async with httpx.AsyncClient(timeout=10, headers={"X-API-Key": key}) as c:
        for path in ("/v1/portforward", "/v1/openvpn/portforwarded"):
            try:
                resp = await c.get(f"{url}{path}")
            except httpx.HTTPError:
                return None
            if resp.status_code == 200:
                port = (resp.json() or {}).get("port")
                return int(port) if port else None
    return None


async def sync_slskd_port() -> int | None:
    """Nastaví slskd port z VPN, když se liší. Vrátí nový port, jinak None."""
    url = os.environ.get("SLSK_GLUETUN_CONTROL_URL")
    key = os.environ.get("SLSK_GLUETUN_CONTROL_API_KEY")
    if not url or not key:
        return None
    port = await forwarded_port(url.rstrip("/"), key)
    if not port:
        return None
    from app.providers import SlskdProvider

    slskd = SlskdProvider()
    async with httpx.AsyncClient(base_url=slskd.base_url, headers=slskd._headers(), timeout=15) as c:
        current = (((await c.get("/api/v0/options")).json() or {}).get("soulseek") or {}).get("listenPort")
        if current == port:
            return None
        resp = await c.patch("/api/v0/options", json={"soulseek": {"listenPort": port}})
        resp.raise_for_status()
    logger.info("slskd: port z VPN %s (byl %s)", port, current)
    return port
