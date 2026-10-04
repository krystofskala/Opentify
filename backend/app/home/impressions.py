"""Zápis toho, co Domů ukázalo (HomeImpression) -- měření doporučování.

Jen položky s vlastní stránkou (mixy, playlisty: `items[].id`), jednou za
den a profil; opakované načtení Domů už nic nepíše (paměť procesu). Nesmí
nikdy shodit Domů."""

from __future__ import annotations

import logging
from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from sqlmodel import Session

from app.db import engine
from app.models import HomeImpression

logger = logging.getLogger(__name__)
_TZ = ZoneInfo("Europe/Prague")
_done: set[tuple[str, str, int]] = set()  # (profil, den, otisk Domů)


def record(user_id: str, home: dict[str, Any]) -> int:
    day = datetime.now(_TZ).date().isoformat()
    rows: dict[str, tuple[str | None, int]] = {}
    for section in home.get("sections") or []:
        sid = section.get("id")
        for pos, item in enumerate(section.get("items") or []):
            if isinstance(item, dict) and item.get("id") and item["id"] not in rows:
                rows[str(item["id"])] = (sid, pos)
    if not rows:
        return 0
    stamp = (user_id, day, hash(frozenset(rows)))
    if stamp in _done:
        return 0
    try:
        with Session(engine) as session:
            for item_id, (sid, pos) in rows.items():
                if session.get(HomeImpression, (user_id, day, item_id)) is None:
                    session.add(HomeImpression(user_id=user_id, day=day, item_id=item_id, section=sid, position=pos))
            session.commit()
        _done.add(stamp)
        if len(_done) > 5000:
            _done.clear()
    except Exception:  # noqa: BLE001 -- měření nesmí shodit Domů
        logger.exception("impressions se nepodařilo zapsat")
        return 0
    return len(rows)
