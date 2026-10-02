"""Statistika stahování za posledních N dní (výchozí 7).

    python -m app.tools.download_stats [dny]
"""

from __future__ import annotations

import statistics
import sys
from collections import Counter, defaultdict
from datetime import timedelta

from sqlmodel import Session, select

from app.db import engine
from app.models import MediaAsset, ProvisioningJob, ProvisioningJobStatus
from app.utils import utcnow


def _aware(v):  # type: ignore[no-untyped-def]
    from datetime import timezone

    return v if v.tzinfo else v.replace(tzinfo=timezone.utc)


def pct(values: list[float], p: float) -> float:
    if not values:
        return 0.0
    values = sorted(values)
    return values[min(len(values) - 1, int(len(values) * p))]


def main(days: int) -> None:
    since = utcnow() - timedelta(days=days)
    with Session(engine) as session:
        jobs = session.exec(select(ProvisioningJob).where(ProvisioningJob.created_at >= since)).all()
        by_status = Counter(j.status.value for j in jobs)
        print(f"== jobů za {days} dní: {len(jobs)}  {dict(by_status)}")
        durations: dict[str, list[float]] = defaultdict(list)
        waits: list[float] = []
        attempts = Counter()
        for j in jobs:
            attempts[j.attempts] += 1
            if j.started_at and j.created_at:
                waits.append((_aware(j.started_at) - _aware(j.created_at)).total_seconds())
            if j.status == ProvisioningJobStatus.SUCCEEDED and j.started_at and j.finished_at:
                src = j.source_provider
                if src is None:
                    asset = session.get(MediaAsset, j.recording_id)
                    src = asset.source_provider if asset else "?"
                mode = "" if j.interactive is None else (" klik" if j.interactive else " pozadí")
                durations[f"{src}{mode}"].append((_aware(j.finished_at) - _aware(j.started_at)).total_seconds())
        print(f"pokusů na job: {dict(sorted(attempts.items()))}")
        if waits:
            print(
                f"čekání ve frontě (s): medián {statistics.median(waits):.0f}, p90 {pct(waits, 0.9):.0f}, "
                f"p99 {pct(waits, 0.99):.0f}, max {max(waits):.0f}"
            )
        for src, ds in sorted(durations.items(), key=lambda kv: -len(kv[1])):
            print(
                f"stažení {src:18s} n={len(ds):5d}  medián {statistics.median(ds):6.1f} s  p90 {pct(ds, 0.9):6.1f}  "
                f"p99 {pct(ds, 0.99):6.1f}  max {max(ds):7.1f}"
            )
        failed = [j for j in jobs if j.status == ProvisioningJobStatus.FAILED]
        reasons = Counter()
        for j in failed:
            msg = (j.error_message or "").lower()
            if "nemá" in msg and "verzi" in msg:
                key = "přísná verze: nic neprošlo"
            elif "žádný vhodný soubor" in msg and "youtube" in msg:
                key = "slskd nic + youtube chyba"
            elif "sign in" in msg or "bot" in msg:
                key = "youtube bot-blok"
            elif "403" in msg:
                key = "youtube 403"
            elif "nedokončeno" in msg or "zasekl" in msg or "nezačal" in msg:
                key = "slskd peer timeout"
            elif "database is locked" in msg:
                key = "DB zamčená"
            else:
                key = msg[:70]
            reasons[key] += 1
        print(f"== selhalo {len(failed)}:")
        for k, n in reasons.most_common(15):
            print(f"  {n:4d}  {k}")
        stuck = [
            j for j in jobs
            if j.status in (ProvisioningJobStatus.RUNNING, ProvisioningJobStatus.PENDING)
            and _aware(j.created_at) < utcnow() - timedelta(minutes=30)
        ]
        print(f"== visí (>30 min PENDING/RUNNING): {len(stuck)}")
        for j in stuck[:10]:
            print(f"  {j.id[:8]} {j.status.value} od {j.created_at} pokus {j.attempts}")


if __name__ == "__main__":
    main(int(sys.argv[1]) if len(sys.argv) > 1 else 7)
