"""qBittorrent Web API (kontejner `qbittorrent`, síť sdílí s gluetun -- celý
provoz torrentů jde přes Mullvad). Port 8080 není publikovaný na hostitele;
z Docker sítě se pouští bez hesla (AuthSubnetWhitelist v jeho nastavení),
volitelně `QBIT_USERNAME` / `QBIT_PASSWORD`."""

from __future__ import annotations

import os

import httpx

CATEGORY = "opentify-mluvene-slovo"


def _base() -> str:
    return os.environ.get("QBIT_URL", "http://gluetun:8080").rstrip("/")


async def _client() -> httpx.AsyncClient:
    c = httpx.AsyncClient(base_url=_base(), timeout=30, headers={"Referer": _base()})
    user = os.environ.get("QBIT_USERNAME", "")
    if user:
        resp = await c.post("/api/v2/auth/login", data={"username": user, "password": os.environ.get("QBIT_PASSWORD", "")})
        resp.raise_for_status()
    return c


async def add(torrent: bytes, infohash: str, save_path: str, stopped: bool = False) -> None:
    """`stopped`: přidat zastavený (výběr souborů před spuštěním)."""
    flag = "true" if stopped else "false"
    async with await _client() as c:
        resp = await c.post(
            "/api/v2/torrents/add",
            files={"torrents": (f"{infohash}.torrent", torrent, "application/x-bittorrent")},
            data={"savepath": save_path, "category": CATEGORY, "stopped": flag, "paused": flag, "root_folder": "true"},
        )
        resp.raise_for_status()
        if resp.text.strip().lower().startswith("fails"):
            raise RuntimeError("qBittorrent torrent nepřijal")


async def set_priority(infohash: str, indices: list[int], priority: int) -> None:
    """0 = nestahovat, 1 = stahovat (jen vybrané soubory sbírky)."""
    if not indices:
        return
    async with await _client() as c:
        resp = await c.post(
            "/api/v2/torrents/filePrio",
            data={"hash": infohash, "id": "|".join(str(i) for i in indices), "priority": str(priority)},
        )
        resp.raise_for_status()


async def start(infohash: str) -> None:
    async with await _client() as c:
        resp = await c.post("/api/v2/torrents/start", data={"hashes": infohash})
        if resp.status_code == 404:  # starší qBittorrent
            resp = await c.post("/api/v2/torrents/resume", data={"hashes": infohash})
        resp.raise_for_status()


async def info(infohash: str) -> dict | None:
    async with await _client() as c:
        resp = await c.get("/api/v2/torrents/info", params={"hashes": infohash})
        resp.raise_for_status()
        items = resp.json()
        return items[0] if items else None


async def files(infohash: str) -> list[dict]:
    async with await _client() as c:
        resp = await c.get("/api/v2/torrents/files", params={"hash": infohash})
        resp.raise_for_status()
        return resp.json()
