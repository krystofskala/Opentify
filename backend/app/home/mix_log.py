"""Měření Denních mixů (7m, rozhodnutí kolem 21. 10. 2026): co v nich který
den bylo -- ať jde změřit, jak moc se skladby mezi dny opakují a jestli se
opakované přeskakují víc. Nic se tím nemění, jen zapisuje.

Snímek `mixlog:<profil>:<den>` = {"mixes": {"1": [skladby], ...}}; drží se
21 dní. Vyhodnocení: `python -m app.home.mix_log` (po profilech).
"""

from __future__ import annotations

from collections import Counter, defaultdict
from datetime import date, timedelta

from sqlmodel import Session, select

from app.db import engine

KEEP_DAYS = 21


def _key(user_id: str, day: str) -> str:
    return f"mixlog:{user_id}:{day}"


def record(user_id: str, day: str, mixes: dict[str, list[str]]) -> None:
    from app.models import HomeSnapshot
    from app.utils import utcnow

    with Session(engine) as session:
        row = session.get(HomeSnapshot, _key(user_id, day)) or HomeSnapshot(key=_key(user_id, day))
        row.payload = {"mixes": mixes}
        row.generated_at = utcnow()
        session.add(row)
        old = (date.fromisoformat(day) - timedelta(days=KEEP_DAYS)).isoformat()
        for snap in session.exec(
            select(HomeSnapshot).where(HomeSnapshot.key.like(f"mixlog:{user_id}:%"))  # type: ignore[attr-defined]
        ).all():
            if snap.key.rsplit(":", 1)[-1] < old:
                session.delete(snap)
        session.commit()


def report(user_id: str) -> dict:
    """Opakování skladeb mezi dny a přeskakování opakovaných vs. nových."""
    from app.models import HomeSnapshot, PlayEvent, Playlist

    with Session(engine) as session:
        snaps = session.exec(
            select(HomeSnapshot).where(HomeSnapshot.key.like(f"mixlog:{user_id}:%"))  # type: ignore[attr-defined]
        ).all()
        days = sorted((s.key.rsplit(":", 1)[-1], (s.payload or {}).get("mixes") or {}) for s in snaps)
        mix_ids = {
            p.source.rsplit(":", 1)[-1]: p.id
            for p in session.exec(
                select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source.like("personal:daily-mix:%"))  # type: ignore[attr-defined]
            ).all()
        }
        events = session.exec(
            select(PlayEvent.playlist_id, PlayEvent.recording_id, PlayEvent.end_reason, PlayEvent.ended_at).where(
                PlayEvent.user_id == user_id, PlayEvent.playlist_id.in_(list(mix_ids.values()))  # type: ignore[attr-defined]
            )
        ).all()
    played: dict[tuple[str, str], list[str]] = defaultdict(list)  # (den, skladba) -> konce přehrání
    for _pid, rid, reason, ended in events:
        played[(ended.date().isoformat(), rid)].append(reason)
    overlaps = []
    seen_before: Counter = Counter()
    repeated = Counter()
    fresh = Counter()
    prev: set[str] = set()
    for day, mixes in days:
        today = {r for ids in mixes.values() for r in ids}
        if prev:
            overlaps.append(len(today & prev) / max(1, len(today)))
        for rid in today:
            bucket = repeated if seen_before[rid] else fresh
            for reason in played.get((day, rid), []):
                bucket[reason] += 1
        for rid in today:
            seen_before[rid] += 1
        prev = today
    rate = lambda c: round(c["skipped"] / max(1, sum(c.values())), 3)  # noqa: E731
    return {
        "dni": len(days),
        "prumerna_shoda_se_vcerejskem": round(sum(overlaps) / len(overlaps), 3) if overlaps else None,
        "preskoceni_opakovanych": rate(repeated), "prehrani_opakovanych": sum(repeated.values()),
        "preskoceni_novych_v_mixu": rate(fresh), "prehrani_novych_v_mixu": sum(fresh.values()),
    }


if __name__ == "__main__":
    from app.models import AppUser

    with Session(engine) as s:
        users = [(u.id, u.name) for u in s.exec(select(AppUser)).all()]
    for uid, name in users:
        print(name, report(uid))
