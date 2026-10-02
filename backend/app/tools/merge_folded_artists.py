"""Sloučí interprety, kteří se liší jen diakritikou / velikostí písmen /
interpunkcí ("KVETY" z tagů vs "Květy" z MusicBrainz). Přísně:

- žádná dvě různá MBID ve skupině (MusicBrainz je vede jako různé),
- žádná dvě různá Deezer id (Deezer je vede jako různé),
- žádný vlastní interpret (own:), žádné `notSameAs` / `homonymOf` mezi nimi,
- důkaz, že jde o stejného: společný název skladby, nebo jeden z řádků je
  čistě z lokálních tagů (bez MBID i Deezer id).

    python -m app.tools.merge_folded_artists [--dry-run]
"""

from __future__ import annotations

import sys
from collections import defaultdict

from sqlmodel import Session, func, select

from app.catalog.artwork import _normalize
from app.db import engine
from app.library.matching import fold_name
from app.models import Artist, FavoriteArtist, Recording, Release


def _has_diacritics(name: str) -> bool:
    import unicodedata

    return any(unicodedata.combining(ch) for ch in unicodedata.normalize("NFD", name))


def _display_name(canon: Artist, dups: list[Artist]) -> str:
    """Hlavní řádek si nechá své jméno, ledaže mu chybí diakritika, kterou
    má jiný ve skupině ("Jablkon" -> "Jablkoň"). Mezi kandidáty s diakritikou
    přednost tomu, kdo není VELKÝMI PÍSMENY."""
    if _has_diacritics(canon.name):
        return canon.name
    with_marks = [a.name for a in dups if _has_diacritics(a.name)]
    if not with_marks:
        return canon.name
    with_marks.sort(key=lambda n: n.isupper())
    return with_marks[0]


def main(dry: bool) -> None:
    from app.catalog.deezer import get_deezer_client
    from app.catalog.musicbrainz import get_musicbrainz_client
    from app.catalog.service import CatalogService

    with Session(engine) as s:
        rec_counts = dict(s.exec(select(Recording.artist_id, func.count()).group_by(Recording.artist_id)).all())
        rel_counts = dict(s.exec(select(Release.artist_id, func.count()).group_by(Release.artist_id)).all())
        groups: dict[str, list[Artist]] = defaultdict(list)
        for a in s.exec(select(Artist)).all():
            refs = a.external_refs or {}
            if refs.get("mergedInto") or refs.get("homonymOf"):
                continue
            if not (rec_counts.get(a.id) or rel_counts.get(a.id)):
                continue
            groups[fold_name(a.name or "")].append(a)

        plans = []
        skipped: dict[str, int] = defaultdict(int)
        for key, rows in groups.items():
            if len(rows) < 2 or not key:
                continue
            if any((a.mbid or "").startswith("own:") for a in rows):
                skipped["vlastní interpret"] += 1
                continue
            mbids = {a.mbid for a in rows if a.mbid}
            if len(mbids) > 1:
                skipped["různá MBID"] += 1
                continue
            dzids = {a.deezer_id for a in rows if a.deezer_id}
            if len(dzids) > 1:
                skipped["různá Deezer id"] += 1
                continue
            ids = {a.id for a in rows}
            if any(set((a.external_refs or {}).get("notSameAs") or []) & ids for a in rows):
                skipped["označeno: není stejný"] += 1
                continue
            canon = max(rows, key=lambda a: (a.mbid is not None, a.deezer_id is not None, rec_counts.get(a.id, 0)))
            canon_titles = {
                _normalize(t) for t in s.exec(select(Recording.title).where(Recording.artist_id == canon.id)).all()
            }
            dups = []
            for a in rows:
                if a.id == canon.id:
                    continue
                titles = {_normalize(t) for t in s.exec(select(Recording.title).where(Recording.artist_id == a.id)).all()}
                shared = len(titles & canon_titles)
                pure_local = a.mbid is None and a.deezer_id is None
                if shared == 0 and not pure_local:
                    skipped["bez důkazu"] += 1
                    continue
                if shared == 0 and len(key.replace(" ", "")) < 6:
                    # Krátké jméno ("Tyler", "Grits") -- jen lokální tag nestačí.
                    skipped["krátké jméno bez společné skladby"] += 1
                    continue
                dups.append((a, shared, pure_local))
            if dups:
                plans.append((canon, dups, _display_name(canon, [d[0] for d in dups])))

        print(f"skupin ke sloučení: {len(plans)}, přeskočeno: {dict(skipped)}")
        for canon, dups, new_name in plans:
            line = ", ".join(
                f"{a.name} ({rec_counts.get(a.id, 0)} skl., společné {shared}{', lokální' if local else ''})"
                for a, shared, local in dups
            )
            rename = f"  [přejmenovat na „{new_name}“]" if new_name != canon.name else ""
            print(f"  -> {canon.name} [{'MBID' if canon.mbid else ''}{' DZ' if canon.deezer_id else ''}] ({rec_counts.get(canon.id, 0)} skl.) <- {line}{rename}")
        if dry:
            return
        svc = CatalogService(s, get_musicbrainz_client(), get_deezer_client())
        for canon, dups, new_name in plans:
            if new_name != canon.name:
                canon.name = new_name
                canon.sort_name = new_name
                s.add(canon)
            for a, _shared, _local in dups:
                svc._merge_artist_into(a, canon)
                for fav in s.exec(select(FavoriteArtist).where(FavoriteArtist.artist_id == a.id)).all():
                    fav.artist_id = canon.id
                    s.add(fav)
        s.commit()
        print("sloučeno")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
