"""Historie poslechu mluveného slova po dnech (kniha / epizoda -> sekundy).

Dřív se ukládala jen poslední pozice (`SpokenProgress`, `PodcastProgress`),
takže nešlo ukázat historii, spočítat hodiny za rok (Wrapped) ani poznat
opuštěné knihy. Čas se počítá z ukládání pozice (appka ho posílá každých
~15 s a při pauze): posun vpřed ve stejném souboru = poslouchaný čas,
nejvýš 3 minuty na jedno uložení (přeskočení dopředu / dlouhý výpadek se
nepočítá jako poslech); nový díl knihy = jeho dosavadní pozice, taky max
3 minuty. Den podle českého času.

Soukromí: jen vlastní profil, nic nikam neodchází (žádný scrobbling).
"""

from __future__ import annotations

from datetime import datetime
from typing import Any
from zoneinfo import ZoneInfo

from sqlmodel import Session, select

from app.models import SpokenListenDay
from app.utils import utcnow

MAX_STEP_MS = 3 * 60 * 1000
_TZ = ZoneInfo("Europe/Prague")


def today() -> str:
    return datetime.now(_TZ).date().isoformat()


def listened_ms(prev_file: str | None, prev_pos: int | None, file_id: str | None, pos: int) -> int:
    """Kolik se poslouchalo mezi dvěma uloženími pozice."""
    if prev_pos is None:
        return 0  # první uložení -- není s čím porovnat
    if file_id is not None and prev_file is not None and file_id != prev_file:
        return min(max(pos, 0), MAX_STEP_MS)  # další díl knihy
    delta = pos - prev_pos
    return delta if 0 < delta <= MAX_STEP_MS else 0


def record(session: Session, user_id: str, kind: str, ref: str, ms: int) -> None:
    """Přičte čas k dnešku (volá se v transakci uložení pozice)."""
    if ms <= 0:
        return
    day = today()
    row = session.exec(
        select(SpokenListenDay).where(
            SpokenListenDay.user_id == user_id, SpokenListenDay.kind == kind,
            SpokenListenDay.ref == ref, SpokenListenDay.day == day,
        )
    ).first() or SpokenListenDay(user_id=user_id, kind=kind, ref=ref, day=day)
    row.seconds = (row.seconds or 0) + ms / 1000
    row.updated_at = utcnow()
    session.add(row)


def days(session: Session, user_id: str, limit_days: int = 60) -> list[dict[str, Any]]:
    """Posledních `limit_days` dní s poslechem: den -> položky (nejdelší první)."""
    rows = session.exec(
        select(SpokenListenDay).where(SpokenListenDay.user_id == user_id).order_by(SpokenListenDay.day.desc())  # type: ignore[attr-defined]
    ).all()
    out: dict[str, list[dict[str, Any]]] = {}
    for r in rows:
        if r.day not in out and len(out) >= limit_days:
            break
        out.setdefault(r.day, []).append({"kind": r.kind, "ref": r.ref, "seconds": round(r.seconds or 0)})
    return [{"day": d, "items": sorted(items, key=lambda i: -i["seconds"])} for d, items in out.items()]
