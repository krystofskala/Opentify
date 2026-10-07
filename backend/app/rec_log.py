"""Měření doporučování (plán P0): co Pusť teď / nekonečné hraní nabídlo a
jak to dopadlo.

- `log_batch` -- várka z `/home/play-now` (skladba, pozice, známá/nová).
- `match` -- přehrání (PlayEvent) se připojí ke skladbě z várky téhož
  profilu za posledních `MATCH_HOURS` -> `rec_batch_id`, `rec_slot` a
  `algorithmic=True`. Funguje i se staršími appkami (vše na serveru) a
  opravuje, že nekonečné hraní se dřív tvářilo jako běžná fronta.
- `report` -- přehled po profilech: brzká přeskočení, dohrání, přijetí
  nových, různorodost. Bez toho nejde poznat, jestli změna pomohla.
"""

from __future__ import annotations

from collections import Counter, defaultdict
from datetime import timedelta
from typing import Any

from sqlmodel import Session, select

from app.db import engine
from app.models import RecBatchItem, new_uuid
from app.utils import utcnow

MATCH_HOURS = 12


def log_batch(user_id: str, recording_ids: list[str], new_ids: set[str], mode: str) -> str | None:
    if not recording_ids:
        return None
    batch_id = new_uuid()
    with Session(engine) as session:
        for pos, rid in enumerate(recording_ids):
            session.add(
                RecBatchItem(
                    batch_id=batch_id, user_id=user_id, recording_id=rid, position=pos,
                    slot="new" if rid in new_ids else "familiar", mode=mode,
                )
            )
        session.commit()
    return batch_id


def match(session: Session, user_id: str, recording_id: str, hours: float = MATCH_HOURS) -> RecBatchItem | None:
    since = (utcnow() - timedelta(hours=hours)).replace(tzinfo=None)
    return session.exec(
        select(RecBatchItem)
        .where(
            RecBatchItem.user_id == user_id,
            RecBatchItem.recording_id == recording_id,
            RecBatchItem.created_at >= since,
        )
        .order_by(RecBatchItem.created_at.desc())  # type: ignore[attr-defined]
    ).first()


def report(days: int = 7) -> list[dict[str, Any]]:
    """Po profilech za `days` dní. Přijetí nové = do 14 dní znovu poslechnutá
    mimo várku nebo dohraná ve várce a dána do Oblíbených."""
    from app.models import AppUser, Listen, PlayEvent, Recording

    since = (utcnow() - timedelta(days=days)).replace(tzinfo=None)
    out: list[dict[str, Any]] = []
    with Session(engine) as session:
        names = {u.id: u.name for u in session.exec(select(AppUser)).all()}
        offered = session.exec(select(RecBatchItem).where(RecBatchItem.created_at >= since)).all()
        plays = session.exec(
            select(PlayEvent).where(PlayEvent.started_at >= since, PlayEvent.rec_batch_id.is_not(None))  # type: ignore[union-attr]
        ).all()
        by_user_offer: dict[str, list[RecBatchItem]] = defaultdict(list)
        for item in offered:
            by_user_offer[item.user_id].append(item)
        by_user_play: dict[str, list[PlayEvent]] = defaultdict(list)
        for p in plays:
            by_user_play[p.user_id].append(p)
        rec_ids = {p.recording_id for p in plays}
        artist_of = dict(
            session.exec(select(Recording.id, Recording.artist_id).where(Recording.id.in_(list(rec_ids)))).all()  # type: ignore[attr-defined]
        ) if rec_ids else {}
        for user_id in sorted(set(by_user_offer) | set(by_user_play), key=lambda u: names.get(u, u)):
            items = by_user_offer.get(user_id, [])
            ps = sorted(by_user_play.get(user_id, []), key=lambda p: p.started_at)
            reasons = Counter(p.end_reason for p in ps)
            new_plays = [p for p in ps if p.rec_slot == "new"]
            accepted = 0
            for p in new_plays:
                later = session.exec(
                    select(Listen.id).where(
                        Listen.user_id == user_id,
                        Listen.recording_id == p.recording_id,
                        Listen.played_at > p.ended_at,
                        Listen.played_at <= p.ended_at + timedelta(days=14),
                    )
                ).first()
                if later:
                    accepted += 1
            # Různorodost: různí interpreti na 20 algoritmických přehrání.
            windows = [ps[i : i + 20] for i in range(0, len(ps) - 19, 20)] or ([ps] if ps else [])
            diversity = (
                round(sum(len({artist_of.get(p.recording_id) for p in w}) * 20 / len(w) for w in windows) / len(windows), 1)
                if windows else None
            )
            n = len(ps) or 1
            out.append({
                "userId": user_id,
                "name": names.get(user_id, "?"),
                "batches": len({i.batch_id for i in items}),
                "offered": len(items),
                "played": len(ps),
                "earlySkipPct": round(100 * reasons.get("skipped", 0) / n),
                "completedPct": round(100 * reasons.get("completed", 0) / n),
                "newPlayed": len(new_plays),
                "newCompletedPct": round(100 * sum(1 for p in new_plays if p.end_reason == "completed") / (len(new_plays) or 1)),
                "newAccepted": accepted,
                "artistsPer20": diversity,
            })
    return out
