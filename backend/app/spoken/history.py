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
MAX_SPEED = 3.0  # nejvyšší rychlost přehrávání v appce (a rezerva)
_TZ = ZoneInfo("Europe/Prague")


def today() -> str:
    return datetime.now(_TZ).date().isoformat()


def listened_ms(
    prev_file: str | None, prev_pos: int | None, file_id: str | None, pos: int, elapsed_ms: float | None = None
) -> int:
    """Kolik se poslouchalo mezi dvěma uloženími pozice. Strop je čas, který
    od minulého uložení opravdu uběhl (× nejvyšší rychlost) -- výpadek signálu
    v autě se tak nezahodí a skok dopředu se nepočítá (audit 8. 10.). Bez
    známého času (starší řádek) pevné 3 minuty."""
    if prev_pos is None:
        return 0  # první uložení -- není s čím porovnat
    cap = MAX_STEP_MS if elapsed_ms is None else max(0.0, elapsed_ms) * MAX_SPEED + 5000
    if file_id is not None and prev_file is not None and file_id != prev_file:
        return int(min(max(pos, 0), cap, MAX_STEP_MS if elapsed_ms is None else cap))  # další díl knihy
    delta = pos - prev_pos
    return delta if 0 < delta <= cap else 0


def elapsed_since(updated_at) -> float | None:
    if updated_at is None:
        return None
    from app.auth import aware

    return (utcnow() - aware(updated_at)).total_seconds() * 1000


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
    out: dict[str, dict[tuple[str, str], float]] = {}
    for r in rows:
        if r.day not in out and len(out) >= limit_days:
            break
        # Souběžné první uložení mohlo založit dva řádky -- sečíst.
        day = out.setdefault(r.day, {})
        day[(r.kind, r.ref)] = day.get((r.kind, r.ref), 0) + (r.seconds or 0)
    return [
        {"day": d, "items": sorted(({"kind": k, "ref": ref, "seconds": round(sec)} for (k, ref), sec in items.items()),
                                   key=lambda i: -i["seconds"])}
        for d, items in out.items()
    ]
