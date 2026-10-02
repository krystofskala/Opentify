"""Sloučí album, které je v katalogu dvakrát: jednou z MusicBrainz, jednou
jen z Deezeru (na stránce interpreta pak bylo dvakrát). Přísně:

- stejný interpret, PŘESNĚ stejný název (i se závorkou -- "Deluxe",
  "Remaster" zůstávají zvlášť), stejný typ (album/EP/singl),
- právě jedno z MusicBrainz (MBID) a ostatní jen z Deezeru (bez MBID),
- seznamy skladeb se kryjí aspoň z 80 % (nebo deezerová kopie je prázdná),
- žádná vlastní / importovaná alba (own:, YouTube, SoundCloud, ručně).

Skladby se spárují podle přesného názvu a sloučí se vším, co na ně
odkazuje (soubor, knihovna, playlisty, poslechy...), viz
app/maintenance/dedupe.py. Vždy nejdřív --dry-run, předtím záloha DB.

    python -m app.tools.merge_duplicate_releases [--dry-run]
"""

from __future__ import annotations

import sys
import unicodedata
from collections import defaultdict

from sqlmodel import Session, select

from app.db import engine
from app.maintenance import dedupe
from app.models import Recording, Release

_IMPORTED = {"youtube", "soundcloud", "manual"}


def _key(title: str) -> str:
    return " ".join(unicodedata.normalize("NFC", title or "").casefold().split())


def main(dry: bool) -> None:
    with Session(engine) as s:
        groups: dict[tuple[str, str], list[Release]] = defaultdict(list)
        for r in s.exec(select(Release)).all():
            if not r.artist_id or (r.mbid or "").startswith("own:"):
                continue
            if (r.external_refs or {}).get("source") in _IMPORTED:
                continue
            groups[(r.artist_id, _key(r.title))].append(r)

        plans: list[tuple[Release, Release, float]] = []
        skipped: dict[str, int] = defaultdict(int)
        for (_artist, _title), rows in groups.items():
            if len(rows) < 2:
                continue
            mb = [r for r in rows if r.mbid]
            dz = [r for r in rows if not r.mbid and r.deezer_id]
            if len(mb) != 1 or not dz:
                skipped["ne právě jedno MB + deezer"] += 1
                continue
            canon = mb[0]
            canon_recs = s.exec(select(Recording).where(Recording.release_id == canon.id)).all()
            canon_titles = {dedupe.track_key(r.title) for r in canon_recs}
            canon_map = {dedupe.track_key(r.title): r for r in canon_recs}
            for src in dz:
                if (src.release_type or "album") != (canon.release_type or "album"):
                    skipped["jiný typ"] += 1
                    continue
                if canon.deezer_id and src.deezer_id and canon.deezer_id != src.deezer_id:
                    skipped["jiné Deezer id"] += 1
                    continue
                src_titles = s.exec(select(Recording.title).where(Recording.release_id == src.id)).all()
                titles = {dedupe.track_key(t) for t in src_titles}
                if titles and canon_titles:
                    matched = {t for t in set(src_titles) if dedupe.find_twin(t, canon_map) is not None}
                    overlap = len({dedupe.track_key(t) for t in matched}) / min(len(titles), len(canon_titles))
                elif not titles:
                    overlap = 1.0  # prázdná deezerová kopie
                else:
                    overlap = 0.0
                if overlap < 0.8:
                    skipped["tracklist se nekryje"] += 1
                    continue
                plans.append((src, canon, overlap))

        print(f"alb ke sloučení: {len(plans)}, přeskočeno: {dict(skipped)}")
        for src, canon, overlap in plans[:40]:
            print(f"  {canon.title!r} ({canon.release_type}) <- deezer kopie, shoda {overlap:.0%}")
        if len(plans) > 40:
            print(f"  ... a dalších {len(plans) - 40}")
        if dry:
            return
        for src, canon, _o in plans:
            dedupe.merge_release(s, src, canon)
        s.commit()
        print(f"sloučeno, statistiky: {dict(dedupe.stats)}")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
