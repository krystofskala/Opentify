"""Úklid zdvojených interpretů (živě: Lana Del Rey 3× v hledání).

1. Řádky se `mergedInto` (sloučené duplikáty) -- jejich alba a skladby, co
   u nich zůstaly, přesunout na hlavní řádek; sám na sebe ukazující
   `mergedInto` smazat.
2. Stejné jméno + stejná fotka + STEJNÉ Deezer id -> jeden řádek (jistý
   duplikát). Různá Deezer id se slučují jen ověřeně podle diskografie
   (hledání), fotka sama nestačí -- fake/výběrové profily ji přebírají.

    python -m app.tools.merge_duplicate_artists [--dry-run]
"""

from __future__ import annotations

import sys
from collections import defaultdict

from sqlmodel import Session, func, select

from app.catalog.deezer_ingest import is_placeholder_picture
from app.db import engine
from app.models import Artist, Recording, Release


def _final(session: Session, artist: Artist) -> Artist:
    seen = {artist.id}
    for _ in range(5):
        target = (artist.external_refs or {}).get("mergedInto")
        if not target or target in seen:
            break
        nxt = session.get(Artist, target)
        if nxt is None:
            break
        seen.add(nxt.id)
        artist = nxt
    return artist


def _move(session: Session, src: Artist, dst: Artist) -> int:
    moved = 0
    for model in (Release, Recording):
        for row in session.exec(select(model).where(model.artist_id == src.id)).all():
            row.artist_id = dst.id
            session.add(row)
            moved += 1
    return moved


def run(dry: bool) -> None:
    with Session(engine) as session:
        artists = session.exec(select(Artist)).all()
        moved = fixed_self = merged = 0
        # 1) existující sloučené duplikáty
        for a in artists:
            target = (a.external_refs or {}).get("mergedInto")
            if not target:
                continue
            if target == a.id:
                refs = dict(a.external_refs)
                refs.pop("mergedInto")
                a.external_refs = refs
                session.add(a)
                fixed_self += 1
                continue
            final = _final(session, a)
            if final.id != a.id:
                moved += _move(session, a, final)
        # 2) stejné jméno + stejná fotka
        groups: dict[tuple[str, str], list[Artist]] = defaultdict(list)
        for a in artists:
            refs = a.external_refs or {}
            # Ručně oddělení jmenovci (Marsyas CZ × FR) a vlastní hudba -- nikdy.
            if (
                refs.get("mergedInto")
                or refs.get("homonymOf")
                or refs.get("notMine")
                or refs.get("notSameAs")
                or (a.mbid or "").startswith("own:")
            ):
                continue
            image = (a.images or [None])[0]
            if image and not is_placeholder_picture(image):
                groups[(a.name.strip().lower(), image)].append(a)
        counts = dict(
            session.exec(select(Recording.artist_id, func.count()).group_by(Recording.artist_id)).all()
        )
        for (name, _image), rows in groups.items():
            if len(rows) < 2:
                continue
            mbids = {r.mbid for r in rows if r.mbid}
            if len(mbids) > 1:
                continue  # dvě různá MBID = různí interpreti, nesahat
            # Fotka nestačí (fake/výběrový profil ji převezme) -- tady jen
            # jistota: stejné Deezer id. Ostatní slučuje ověřeně (společná alba)
            # hledání, viz CatalogService._merge_verified_duplicates.
            if len({r.deezer_id for r in rows}) != 1:
                continue
            rows.sort(key=lambda r: (r.mbid is None, -counts.get(r.id, 0)))
            canon = rows[0]
            for dup in rows[1:]:
                print(f"merge {name}: {dup.id[:8]} (dz {dup.deezer_id}) -> {canon.id[:8]}")
                moved += _move(session, dup, canon)
                dup.external_refs = {**(dup.external_refs or {}), "mergedInto": canon.id}
                session.add(dup)
                merged += 1
        print(f"self-merge fixed {fixed_self}, merged {merged}, rows moved {moved}")
        if dry:
            session.rollback()
            print("(dry run)")
        else:
            session.commit()


if __name__ == "__main__":
    run(dry="--dry-run" in sys.argv)
