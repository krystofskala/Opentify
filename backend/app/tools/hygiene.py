"""Úklid dat po testech a smazaných profilech:
- nepoužité pozvánky smazaných profilů -> prošlé (kód by jinak ještě týden
  platil a vedl na neexistující profil); společný registrační odkaz
  (`*signup*`) se nechává,
- fronta stahování: řádky z benchmarků (`requested_by_user_id` začíná
  "bench" nebo "esc-") -- nejde o hudbu, kterou někdo chtěl, jen kazí
  statistiky. Stažené soubory zůstávají.

    python -m app.tools.hygiene [--dry-run]"""
from __future__ import annotations

import sys

from sqlalchemy import or_
from sqlmodel import Session, select

from app.db import engine
from app.models import AppUser, InviteCode, ProvisioningJob
from app.routes.auth import SIGNUP
from app.auth import aware
from app.utils import utcnow

BENCH_PREFIXES = ("bench", "esc-")


def stale_invites(session: Session) -> list[InviteCode]:
    users = set(session.exec(select(AppUser.id)).all())
    now = utcnow()
    return [
        inv for inv in session.exec(select(InviteCode).where(InviteCode.used_at.is_(None))).all()  # type: ignore[union-attr]
        if inv.user_id != SIGNUP and inv.user_id not in users and aware(inv.expires_at) > now
    ]


def bench_jobs(session: Session) -> list[ProvisioningJob]:
    return list(session.exec(
        select(ProvisioningJob).where(or_(*(ProvisioningJob.requested_by_user_id.startswith(p) for p in BENCH_PREFIXES)))  # type: ignore[attr-defined]
    ).all())


def main(dry: bool) -> None:
    with Session(engine) as session:
        invites = stale_invites(session)
        jobs = bench_jobs(session)
        print(f"pozvánky smazaných profilů (nepoužité, platné): {len(invites)}")
        for inv in invites:
            print(f"  {inv.id} profil {inv.user_id} platí do {inv.expires_at}")
        print(f"úlohy stahování z benchmarků: {len(jobs)}")
        for job in jobs[:20]:
            print(f"  {job.id} {job.requested_by_user_id} {job.status.value if hasattr(job.status, 'value') else job.status}")
        if dry:
            print("(nanečisto)")
            return
        now = utcnow()
        for inv in invites:
            inv.expires_at = now
            session.add(inv)
        for job in jobs:
            session.delete(job)
        session.commit()
        print("uloženo")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
