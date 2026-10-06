"""Upozornění správci na telefon (ntfy).

`NTFY_URL` = adresa kanálu, např. `https://ntfy.sh/<tajný-kanál>`; bez ní se
nic neposílá. Odesílá se na pozadí (vlákno), nikdy neshodí požadavek a
stejná událost (`key`) se pošle nejvýš jednou za `every_s`. Do zpráv nic
citlivého (žádné klíče, hesla) -- kanál je tajný, ne šifrovaný.
"""

from __future__ import annotations

import logging
import os
import threading
import time

import httpx

logger = logging.getLogger(__name__)
_last: dict[str, float] = {}
_lock = threading.Lock()


def _target() -> tuple[str, str] | None:
    url = os.environ.get("NTFY_URL", "").strip().rstrip("/")
    if not url or "/" not in url.split("://", 1)[-1]:
        return None
    base, topic = url.rsplit("/", 1)
    return base + "/", topic


def notify(title: str, message: str, *, tags: list[str] | None = None, priority: int = 3,
           key: str | None = None, every_s: float = 0) -> bool:
    """`True` = odesláno (na pozadí), `False` = vypnuto nebo potlačeno."""
    target = _target()
    if target is None:
        return False
    if key and every_s:
        now = time.monotonic()
        with _lock:
            if now - _last.get(key, -every_s) < every_s:
                return False
            _last[key] = now
    base, topic = target
    payload = {"topic": topic, "title": title, "message": message, "tags": tags or [], "priority": priority}

    def send() -> None:
        try:
            httpx.post(base, json=payload, timeout=10).raise_for_status()
        except Exception as e:  # noqa: BLE001 -- upozornění nesmí nic rozbít
            logger.warning("upozornění se nepodařilo odeslat: %s", e)

    threading.Thread(target=send, daemon=True).start()
    return True
