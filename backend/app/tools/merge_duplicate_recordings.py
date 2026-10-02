"""Sloučí skladbu, která je na STEJNÉM albu dvakrát (MusicBrainz tracklist +
kopie z Deezeru/Spotify/skenu, rozdíl jen v apostrofu, mezeře, diakritice).
Přísně:

- stejné album, stejný název podle `dedupe.track_key` (verze v závorce
  rozhoduje: "Ride" a "Ride (Live)" zůstanou zvlášť),
- nejvýš jedno MBID a nejvýš jedno ISRC (dvě různá = dvě různé nahrávky),
- čísla stop se neliší (jedno může chybět).

Hlavní: s MBID, pak s číslem stopy, pak se staženým souborem. Všechno, co
odkazuje na duplikát, se přesune (dedupe.merge_recording). Nejdřív
--dry-run, předtím záloha DB.

    python -m app.tools.merge_duplicate_recordings [--dry-run]
"""

from __future__ import annotations

import sys
from collections import defaultdict

from sqlmodel import Session, select

from app.db import engine
from app.maintenance import dedupe
from app.models import MediaAsset, MediaAssetStatus, Recording


def main(dry: bool) -> None:
    with Session(engine) as s:
        groups: dict[tuple[str, str], list[Recording]] = defaultdict(list)
        for r in s.exec(select(Recording).where(Recording.release_id.is_not(None))).all():  # type: ignore[union-attr]
            if (r.mbid or "").startswith("own:"):
                continue
            groups[(r.release_id, dedupe.track_key(r.title))].append(r)

        def available(rid: str) -> bool:
            a = s.get(MediaAsset, rid)
            return a is not None and a.status == MediaAssetStatus.AVAILABLE

        plans: list[tuple[Recording, list[Recording]]] = []
        skipped: dict[str, int] = defaultdict(int)
        for (_rel, key), rows in groups.items():
            if len(rows) < 2 or not key:
                continue
            if len({r.mbid for r in rows if r.mbid}) > 1:
                skipped["různá MBID"] += 1
                continue
            if len({r.isrc for r in rows if r.isrc}) > 1:
                skipped["různá ISRC"] += 1
                continue
            if len({r.track_number for r in rows if r.track_number}) > 1:
                skipped["různá čísla stop"] += 1
                continue
            canon = max(rows, key=lambda r: (r.mbid is not None, r.track_number is not None, available(r.id), r.deezer_id is not None))
            plans.append((canon, [r for r in rows if r.id != canon.id]))

        print(f"skupin ke sloučení: {len(plans)} ({sum(len(d) for _c, d in plans)} duplikátů), přeskočeno: {dict(skipped)}")
        for canon, dups in plans[:25]:
            print(f"  {canon.title!r} <- {[d.title for d in dups]}")
        if dry:
            return
        for canon, dups in plans:
            for d in dups:
                dedupe.merge_recording(s, d, canon)
        s.commit()
        print(f"sloučeno, statistiky: {dict(dedupe.stats)}")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
