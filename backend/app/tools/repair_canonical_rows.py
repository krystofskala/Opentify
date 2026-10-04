"""Vrátí do tracklistu alba staré řádky se souborem / poslechy / lajky.

Po změně kanonické edice (`_canonical_edition`) založil tracklist pro nové
MB nahrávky nové řádky a staré (stažený soubor, poslechy, lajky, playlisty)
z `tracklistIds` vypadly -- album pak ukazovalo skladby bez souboru, soubor
visel mimo. Tady: pro každou skladbu tracklistu bez souboru se hledá
dvojník na témže albu (stejný název včetně verze, délka ±3 s -- u staženého
souboru jeho skutečná délka), na který něco odkazuje. Nový řádek se do něj
sloučí (dedupe.merge_recording, převede všechno), dvojník převezme nové
MBID a jeho id se zapíše do `tracklistIds`. Jiné verze (živá, clean
s jinou délkou) se neslučují, nic unikátního se nemaže.

    python -m app.tools.repair_canonical_rows [--dry-run]

`--dry-run` jen čte (databáze otevřená read-only)."""
from __future__ import annotations

import sys
from collections import Counter

from sqlalchemy import func
from sqlmodel import Session, create_engine, select

from app.catalog.canonical import adopt_mbid, effective_duration, find_referenced_twin, has_file
from app.models import Artist, Recording, Release

stats: Counter = Counter()


def _readonly_engine():
    from app.db import DATABASE_URL

    if not DATABASE_URL.startswith("sqlite:///"):
        raise SystemExit("--dry-run umí jen SQLite")
    path = DATABASE_URL[len("sqlite:///"):]
    return create_engine(f"sqlite:///file:{path}?mode=ro&uri=true", connect_args={"check_same_thread": False})


def plan(session: Session) -> list[tuple[Release, Recording, Recording]]:
    """(album, nový řádek tracklistu bez souboru, starý dvojník s odkazy)."""
    out = []
    releases = session.exec(
        select(Release).where(func.json_extract(Release.external_refs, "$.tracklistIds").is_not(None))
    ).all()
    for release in releases:
        ids = (release.external_refs or {}).get("tracklistIds") or []
        if not ids:
            continue
        stats["releases"] += 1
        rows = session.exec(select(Recording).where(Recording.release_id == release.id)).all()
        by_id = {r.id: r for r in rows}
        in_tracklist = set(ids)
        candidates = [r for r in rows if r.id not in in_tracklist]
        if not candidates:
            continue
        claimed: set[str] = set()
        for rid in ids:
            rec = by_id.get(rid)
            if rec is None or has_file(session, rec.id):
                continue
            twin = find_referenced_twin(session, candidates, rec.title, rec.duration_ms, rec.track_number, claimed)
            if twin is None:
                continue
            claimed.add(twin.id)
            out.append((release, rec, twin))
    return out


def apply(session: Session, pairs: list[tuple[Release, Recording, Recording]]) -> None:
    from app.maintenance.dedupe import merge_recording

    for release, rec, twin in pairs:
        # Údaje kanonické nahrávky (řádek se sloučením smaže).
        mbid, title, duration, number, isrc = rec.mbid, rec.title, rec.duration_ms, rec.track_number, rec.isrc
        if mbid:
            adopt_mbid(session, twin, mbid)  # sloučí `rec` do `twin`
        else:
            merge_recording(session, rec, twin)
        twin.title = title
        twin.duration_ms = duration or twin.duration_ms
        twin.track_number = number
        twin.isrc = isrc or twin.isrc
        session.add(twin)
        refs = dict(release.external_refs or {})
        refs["tracklistIds"] = [twin.id if i == rec.id else i for i in refs.get("tracklistIds") or []]
        release.external_refs = refs
        session.add(release)
        session.flush()
        stats["merged"] += 1
    session.commit()


def _describe(session: Session, release: Release, rec: Recording, twin: Recording) -> str:
    artist = session.get(Artist, release.artist_id)
    file_ms = effective_duration(session, twin)
    return (
        f"{artist.name if artist else '?'} – {release.title}: '{rec.title}' "
        f"({(rec.duration_ms or 0) / 1000:.0f} s) <- starý řádek '{twin.title}' "
        f"(soubor {'ano' if has_file(session, twin.id) else 'ne'}, {(file_ms or 0) / 1000:.0f} s)"
    )


def main(dry_run: bool) -> None:
    if dry_run:
        eng = _readonly_engine()
    else:
        from app.db import engine as eng
    with Session(eng) as session:
        pairs = plan(session)
        with_file = sum(1 for _r, _rec, twin in pairs if has_file(session, twin.id))
        print(f"alb s tracklistem: {stats['releases']}, dotčených alb: {len({r.id for r, _a, _b in pairs})}, "
              f"párů: {len(pairs)}, z toho se staženým souborem: {with_file}")
        for release, rec, twin in pairs[:25]:
            print("  ", _describe(session, release, rec, twin))
        if dry_run:
            print("ZKUŠEBNĚ -- nic neuloženo")
            return
        apply(session, pairs)
        print("POUŽITO", dict(stats))


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
