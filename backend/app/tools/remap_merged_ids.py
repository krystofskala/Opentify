"""Jednorázově: odkazy na alba, která zmizela sloučením (dřív merge_release
textové odkazy nepřepisoval). "/releases/<id>" v rozposlouchaných kolekcích
a v kontextu poslechů, jehož album už neexistuje, se namíří na album, kterému
teď patří skladba ze stejného řádku (víc řádků = většina). Stejná náhrada se
pak provede i ve snímcích Domů. Album, které nejde dohledat, zůstane, jak je.

    python -m app.tools.remap_merged_ids [--dry-run]"""
from __future__ import annotations

import sys
from collections import Counter, defaultdict

from sqlmodel import Session, select

from app.db import engine
from app.maintenance import dedupe
from app.models import CollectionProgress, Listen, Recording, Release

PREFIX = "/releases/"


def _release_id(route: str | None) -> str | None:
    if not route or not route.startswith(PREFIX):
        return None
    rid = route[len(PREFIX):].split("/", 1)[0].split("?", 1)[0]
    return rid or None


def find_mapping(session: Session) -> tuple[dict[str, str], dict[str, int]]:
    """{staré id alba: nové id} + počty řádků, které nešlo dohledat."""
    votes: dict[str, Counter] = defaultdict(Counter)
    rows: list[tuple[str | None, str]] = []
    for route, rec_id in session.exec(
        select(CollectionProgress.route, CollectionProgress.recording_id).where(CollectionProgress.route.like(PREFIX + "%"))  # type: ignore[attr-defined]
    ).all():
        rows.append((_release_id(route), rec_id))
    for context, rec_id in session.exec(
        select(Listen.context, Listen.recording_id).where(Listen.context.like(PREFIX + "%"))  # type: ignore[union-attr]
    ).all():
        rows.append((_release_id(context), rec_id))
    old_ids = {rid for rid, _ in rows if rid}
    existing = set(session.exec(select(Release.id).where(Release.id.in_(list(old_ids)))).all()) if old_ids else set()  # type: ignore[attr-defined]
    unresolved: Counter = Counter()
    for rid, rec_id in rows:
        if not rid or rid in existing:
            continue
        rec = session.get(Recording, rec_id) if rec_id else None
        if rec is None or not rec.release_id or session.get(Release, rec.release_id) is None:
            unresolved[rid] += 1
            continue
        votes[rid][rec.release_id] += 1
    mapping = {old: c.most_common(1)[0][0] for old, c in votes.items()}
    return mapping, {k: v for k, v in unresolved.items() if k not in mapping}


def main(dry: bool) -> None:
    with Session(engine) as session:
        mapping, unresolved = find_mapping(session)
        print(f"alb k přemapování: {len(mapping)}, nedohledaných: {len(unresolved)}")
        for old, new in mapping.items():
            rel = session.get(Release, new)
            print(f"  {old} -> {new} ({rel.title if rel else '?'})")
        for old, n in unresolved.items():
            print(f"  ? {old} ({n} řádků, skladba bez alba / smazaná)")
        dedupe.remap_release_refs(session, mapping)
        print("statistiky:", dict(dedupe.stats))
        if dry:
            session.rollback()
            print("(nanečisto)")
            return
        session.commit()
        print("uloženo")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
