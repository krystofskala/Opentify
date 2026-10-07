"""#57: rozpadlé kompilace ("100% Handmade Music Volume I" jako 7 mini alb
po interpretech, import odkazu ze Spotify 6. 10.) zpět pod skutečné album
z MusicBrainz ("Acoustic Disc: 100% Handmade Music, Volume 1", Various
Artists).

Skladba mini alba: stejná skladba (název + délka) na skutečném albu ->
sloučit (soubor, playlisty, poslechy se převedou, `dedupe.merge_recording`),
jinak jen přesunout na skutečné album. Interpret skladby zůstává její
(ne "Various Artists" -- proto ne `dedupe.merge_release`). Prázdné mini
album se smaže. Nic se nemaže z disku.

Spuštění: `python -m app.tools.fix_compilation_fragments [--apply]`
(bez --apply jen vypíše, co by udělal).
"""

from __future__ import annotations

import re
import sys

from sqlmodel import Session, select

from app.db import engine
from app.maintenance.dedupe import _move_later, find_twin, merge_recording, remap_release_refs, same_length, track_key
from app.models import Artist, Recording, Release

_ROMAN = {"i": 1, "ii": 2, "iii": 3, "iv": 4, "v": 5, "vi": 6, "vii": 7, "viii": 8, "ix": 9, "x": 10}


def volume_key(title: str) -> str | None:
    """"100% Handmade Music Volume I" i "Acoustic Disc:100% Handmade Music,
    Volume 1" -> "100 handmade music 1"."""
    t = re.sub(r"^acoustic disc\s*:\s*", "", title.strip(), flags=re.I)
    m = re.match(r"^(.*?)[,\s]+vol(?:ume)?\.?\s+([ivx]+|\d+)\s*$", t, re.I)
    if not m:
        return None
    n = m.group(2).lower()
    num = _ROMAN.get(n) if not n.isdigit() else int(n)
    base = " ".join(re.sub(r"[^a-z0-9]+", " ", m.group(1).lower()).split())
    return f"{base} {num}" if num else None


def plan(session: Session) -> list[tuple[Release, list[Release]]]:
    """[(skutečné album MB, [mini alba])] -- jen kompilace s víc interprety."""
    real = {}
    for r in session.exec(select(Release).where(Release.mbid.is_not(None), Release.title.like("%Handmade Music%Vol%"))).all():
        if (k := volume_key(r.title)) is not None:
            real[k] = r
    groups: dict[str, list[Release]] = {}
    for r in session.exec(select(Release).where(Release.mbid.is_(None), Release.title.like("%Handmade Music%Vol%"))).all():
        if (k := volume_key(r.title)) is not None and k in real:
            groups.setdefault(k, []).append(r)
    return [(real[k], minis) for k, minis in groups.items()]


def run(apply: bool) -> None:
    with Session(engine) as session:
        for dst, minis in plan(session):
            twins = {track_key(r.title): r for r in session.exec(select(Recording).where(Recording.release_id == dst.id)).all()}
            print(f"== {dst.title} (MB, {len(twins)} skladeb) <- {len(minis)} mini alb")
            for src in minis:
                artist = session.get(Artist, src.artist_id)
                for rec in session.exec(select(Recording).where(Recording.release_id == src.id)).all():
                    twin = find_twin(rec.title, twins)
                    if twin is not None and (twin.id == rec.id or not same_length(rec.duration_ms, twin.duration_ms)):
                        twin = None
                    print(f"   {artist.name if artist else '?'} – {rec.title}: "
                          + (f"sloučit se skladbou alba ({twin.title})" if twin else "přesunout na album"))
                    if not apply:
                        continue
                    if twin is not None:
                        merge_recording(session, rec, twin)
                    else:
                        rec.release_id = dst.id
                        session.add(rec)
                if apply:
                    session.flush()
                    _move_later(session, "album", src.id, dst.id)
                    remap_release_refs(session, {src.id: dst.id})
                    session.delete(src)
                    session.flush()
                print(f"   mini album {artist.name if artist else '?'} / {src.title}: smazat (prázdné)")
        if apply:
            session.commit()
            print("hotovo")
        else:
            print("(nic nezměněno -- spusť s --apply)")


if __name__ == "__main__":
    run("--apply" in sys.argv)
