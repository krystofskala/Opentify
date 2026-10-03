"""Sloučí album, které je v katalogu víckrát jen z Deezeru (různá Deezer id
téhož alba -- reedice, regionální kopie; na stránce interpreta dvakrát).
Přísně:
- stejný interpret, stejný název (bez ohledu na velikost písmen), stejný typ,
- žádné z nich nemá MBID (MB alba řeší merge_duplicate_releases),
- žádná vlastní / importovaná alba (own:, YouTube, SoundCloud, ručně),
- prázdná kopie (0 skladeb) jde do plné; dvě plné jen když se jejich
  seznamy skladeb kryjí aspoň z 80 % VĚTŠÍHO z nich (výběr 5 skladeb
  není totéž co výběr 13).
Cíl = album s víc staženými skladbami, pak s víc skladbami. Všechno, co
odkazuje na skladby, se převede (app/maintenance/dedupe.py).

    python -m app.tools.merge_deezer_twins [--dry-run]"""
from __future__ import annotations

import sys
from collections import Counter, defaultdict

from sqlmodel import Session, select

from app.db import engine
from app.maintenance import dedupe
from app.models import MediaAsset, MediaAssetStatus, Recording, Release


def _skip(rel: Release) -> bool:
    refs = rel.external_refs or {}
    return bool(rel.mbid) or refs.get("source") in ("youtube", "soundcloud", "manual") or (rel.deezer_id or "").startswith("own:")


def main(dry: bool) -> None:
    skipped: Counter = Counter()
    plans: list[tuple[Release, Release, str]] = []
    with Session(engine) as session:
        groups: dict[tuple, list[Release]] = defaultdict(list)
        for rel in session.exec(select(Release).where(Release.mbid.is_(None), Release.deezer_id.is_not(None))).all():  # type: ignore[union-attr]
            if not _skip(rel):
                groups[(rel.artist_id, rel.title.strip().lower(), rel.release_type)].append(rel)
        for rels in groups.values():
            if len(rels) < 2:
                continue
            info = {}
            for rel in rels:
                recs = session.exec(select(Recording).where(Recording.release_id == rel.id)).all()
                avail = sum(
                    1 for r in recs
                    if (a := session.get(MediaAsset, r.id)) is not None and a.status == MediaAssetStatus.AVAILABLE
                )
                info[rel.id] = ({dedupe.track_key(r.title) for r in recs}, avail, len(recs))
            rels.sort(key=lambda r: (info[r.id][1], info[r.id][2]), reverse=True)
            dst = rels[0]
            dst_titles = info[dst.id][0]
            for src in rels[1:]:
                titles = info[src.id][0]
                if not titles:
                    plans.append((src, dst, "prázdná kopie"))
                    continue
                if not dst_titles:
                    skipped["cíl prázdný"] += 1
                    continue
                overlap = len(titles & dst_titles) / max(len(titles), len(dst_titles))
                if overlap >= 0.8:
                    plans.append((src, dst, f"shoda {overlap:.0%}"))
                else:
                    skipped["tracklist se nekryje"] += 1
        print(f"alb ke sloučení: {len(plans)}, přeskočeno: {dict(skipped)}")
        for src, dst, why in plans[:15]:
            print(f"  '{dst.title}' <- {src.deezer_id} ({why})")
        if dry:
            print("(nanečisto)")
            return
        for src, dst, _why in plans:
            dedupe.merge_release(session, src, dst)
        session.commit()
        print("sloučeno, statistiky:", dict(dedupe.stats))


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
