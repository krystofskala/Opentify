"""HTTP klient pro Apple (iTunes Search, Apple Music RSS) -- jen přes Mullvad.

Apple domácí IP nevidí: stejná gluetun proxy jako Open Shazam a importy
odkazů. Bez proxy se Apple vůbec nevolá (`None`) a funkce, které ho
potřebují, se tiše vynechají.
"""

from __future__ import annotations

import os

import httpx

_client: httpx.AsyncClient | None = None


def apple_proxy() -> str | None:
    value = os.environ.get("APPLE_PROXY") or os.environ.get("SHAZAM_PROXY", "http://gluetun:8888")
    return value.strip() or None


def apple_http() -> httpx.AsyncClient | None:
    global _client
    proxy = apple_proxy()
    if proxy is None:
        return None
    if _client is None:
        _client = httpx.AsyncClient(
            proxy=proxy, timeout=20.0, headers={"User-Agent": "Opentify/0.1 (personal music app)"}
        )
    return _client
