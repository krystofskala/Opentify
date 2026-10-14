"""Měření doporučování: týden před a po změně (jen čtení).

    python -m app.tools.rec_report                 # změna 13. 10. 2026, okna po 7 dnech
    python -m app.tools.rec_report --change 2026-10-13 --days 7

Pro každý profil porovná Pusť teď / nekonečné hraní (app/rec_log.py: přeskočeno
na začátku, dohráno, nové – dohráno a přijato, podle zdroje) a přehrávání
z mixů (Objevy týdne, denní mixy, ostatní) podle PlayEvent.source_label.
Na 20. 10. 2026: týden po změnách doporučování z 13. 10.
"""

from __future__ import annotations

import argparse
from collections import defaultdict
from datetime import datetime, timedelta, timezone

from sqlmodel import Session, select

from app import rec_log
from app.db import engine
from app.models import AppUser, PlayEvent


def _mix_group(label: str | None) -> str:
    label = (label or "").strip()
    if label.startswith("Objevy"):
        return "Objevy týdne"
    if label.startswith("Denní mix"):
        return "denní mixy"
    if label.startswith("Tvůj mix") or label.startswith("Rádio"):
        return "mixy kategorií a rádia"
    return ""


def _mix_stats(since: datetime, until: datetime) -> dict[str, dict[str, dict[str, int]]]:
    out: dict[str, dict[str, dict[str, int]]] = defaultdict(lambda: defaultdict(lambda: {"n": 0, "skip": 0, "done": 0}))
    with Session(engine) as session:
        rows = session.exec(
            select(PlayEvent.user_id, PlayEvent.source_label, PlayEvent.end_reason).where(
                PlayEvent.started_at >= since, PlayEvent.started_at < until
            )
        ).all()
    for user_id, label, reason in rows:
        group = _mix_group(label)
        if not group:
            continue
        cell = out[user_id][group]
        cell["n"] += 1
        cell["skip"] += reason == "skipped"
        cell["done"] += reason == "completed"
    return out


def _pct(a: int, b: int) -> str:
    return f"{round(100 * a / b)} %" if b else "–"


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--change", default="2026-10-13")
    ap.add_argument("--days", type=int, default=7)
    args = ap.parse_args()
    change = datetime.fromisoformat(args.change)
    windows = {
        "před": (change - timedelta(days=args.days), change),
        "po": (change, min(change + timedelta(days=args.days), datetime.now(timezone.utc).replace(tzinfo=None))),
    }
    with Session(engine) as session:
        names = {u.id: u.name for u in session.exec(select(AppUser)).all()}
    rep = {k: {r["userId"]: r for r in rec_log.report(since=a, until=b)} for k, (a, b) in windows.items()}
    mixes = {k: _mix_stats(a, b) for k, (a, b) in windows.items()}
    users = sorted(set().union(*rep.values(), *[set(m) for m in mixes.values()]), key=lambda u: names.get(u, u))
    print(f"Změna {args.change}, okna {args.days} dní (po = do teď, když týden ještě neuplynul)\n")
    for user_id in users:
        print(f"== {names.get(user_id, user_id)}")
        for k in ("před", "po"):
            r = rep[k].get(user_id)
            if r:
                print(
                    f"  Pusť teď {k:4}: přehráno {r['played']}, přeskočeno na začátku {r['earlySkipPct']} %, "
                    f"dohráno {r['completedPct']} % | nové: {r['newPlayed']}, dohráno {r['newCompletedPct']} %, přijato {r['newAccepted']}"
                )
                for src, v in sorted((r.get("sources") or {}).items(), key=lambda kv: -kv[1]["played"]):
                    print(f"      zdroj {src:14} přehráno {v['played']:3}, přeskočeno {_pct(v['skipped'], v['played']):>5}, přijato {v['accepted']}")
            else:
                print(f"  Pusť teď {k:4}: nic")
        for group in ("Objevy týdne", "denní mixy", "mixy kategorií a rádia"):
            cells = [mixes[k].get(user_id, {}).get(group) for k in ("před", "po")]
            if not any(cells):
                continue
            txt = []
            for k, c in zip(("před", "po"), cells):
                txt.append(f"{k}: {c['n']} přehrání, přeskočeno {_pct(c['skip'], c['n'])}, dohráno {_pct(c['done'], c['n'])}" if c else f"{k}: nic")
            print(f"  {group}: " + " | ".join(txt))
        print()


if __name__ == "__main__":
    main()
