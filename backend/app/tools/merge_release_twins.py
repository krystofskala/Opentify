"""Sloučí dvojčata alb: stejné album téhož interpreta jednou z MusicBrainz
(MBID, bez Deezer id) a jednou jen z Deezeru (bez MBID). Vznikala, když se
album napřed objevilo přes Deezer (hledání, Domů) a MB skupina přišla až
později z diskografie -- diskografie pak deezerové dvojče jako duplikát
vynechala a otevřené album "chybělo" (živě: Texican Badman, Peter Rowan).

Shoda: stejný interpret, stejný `album_key` (název + slova verze), stejná
třída (album/kompilace vs singl/EP) a stejný rok (± 1) -- reedice s jiným
rokem zůstává zvlášť (může mít jiné nahrávky, živě: Texican Badman 2019). Deezerový řádek se sloučí do MB řádku
(`dedupe.merge_release`: skladby se stejným názvem sloučí, ostatní přesune,
poslechy/knihovna/playlisty přemapuje) -- nic unikátního se nemaže.
Vlastní hudba a importy z YouTube/SoundCloudu se vynechávají.

    python -m app.tools.merge_release_twins [--apply]
"""

from __future__ import annotations

import sys
from collections import defaultdict

from sqlmodel import Session, select

from app.catalog.deezer_ingest import album_key, release_class
from app.db import engine
from app.maintenance import dedupe
from app.models import Release


def _skip(r: Release) -> bool:
    refs = r.external_refs or {}
    return (
        refs.get("source") in ("youtube", "soundcloud", "manual")
        or (r.deezer_id or "").startswith("own:")
        or (r.mbid or "").startswith("own:")
        or bool(refs.get("otherEdition"))
    )


def _distance(a: Release, b: Release) -> int:
    """Vzdálenost dat ve dnech (neznámé = daleko); stejný den = 0."""
    from datetime import date

    def parse(v: str | None) -> date | None:
        v = (v or "")[:10]
        parts = v.split("-")
        try:
            return date(int(parts[0]), int(parts[1]) if len(parts) > 1 else 1, int(parts[2]) if len(parts) > 2 else 1)
        except (ValueError, IndexError):
            return None

    da, db = parse(a.release_date), parse(b.release_date)
    return abs((da - db).days) if da and db else 10**6


_TRIGGERS = {"remix", "remixes", "edit", "mix", "version", "deluxe", "remaster", "remastered", "bonus", "rooftop", "expanded", "anniversary"}
_FILLER = {"feat", "ft", "featuring", "with", "from", "the", "a", "original", "motion", "picture", "soundtrack", "series", "hbo", "an"}


def _bracket_words(title: str | None) -> set[str]:
    import re
    import unicodedata

    text = unicodedata.normalize("NFKD", title or "").encode("ascii", "ignore").decode().lower()
    words: set[str] = set()
    for part in re.findall(r"\(.*?\)|\[.*?\]", text):
        words |= {w for w in re.split(r"[^a-z0-9]+", part) if w and w not in _FILLER}
    return words


def same_edition(a: Release, b: Release) -> bool:
    """Remix / edit / verze / deluxe v závorce musí sedět celé --
    "(Monsieur Adi remix)" není "(Cedric Gervais Remix)" a "Video Games
    (Joris Voorn edit)" není "Video Games" (album_key bere jen slovo "remix")."""
    wa, wb = _bracket_words(a.title), _bracket_words(b.title)
    if not (wa | wb) & _TRIGGERS:
        return True
    # Stejná slova verze a jedna závorka celá obsažená v druhé ("(Young
    # Ruffian remix)" vs "(From Maleficent / Young Ruffian Remix)").
    return wa & _TRIGGERS == wb & _TRIGGERS and (wa <= wb or wb <= wa)


def _years_close(a: Release, b: Release) -> bool:
    ya, yb = (a.release_date or "")[:4], (b.release_date or "")[:4]
    return ya.isdigit() and yb.isdigit() and abs(int(ya) - int(yb)) <= 1


def pairs(session: Session) -> list[tuple[Release, Release]]:
    groups: dict[tuple[str, str], list[Release]] = defaultdict(list)
    for r in session.exec(select(Release)).all():
        if not _skip(r):
            groups[(r.artist_id, album_key(r.title))].append(r)
    out = []
    for rows in groups.values():
        mb = [r for r in rows if r.mbid and not r.deezer_id]
        dz = [r for r in rows if r.deezer_id and not r.mbid]
        # Víc stejnojmenných vydání (dva singly "No Kings") -- párovat
        # nejbližší data napřed, ne první nalezené (křížilo se).
        cands = sorted(
            (
                (_distance(d, m), d.id, m.id, d, m)
                for d in dz
                for m in mb
                if (release_class(m) is None or release_class(d) is None or release_class(m) == release_class(d))
                # Jen totéž vydání (rok ± 1) -- reedice s jiným rokem může mít
                # jiné nahrávky (Texican Badman 2019) a slučování podle názvu
                # skladeb by verze slilo.
                and _years_close(d, m)
                and same_edition(d, m)
            ),
            key=lambda c: c[:3],
        )
        used: set[str] = set()
        for _dist, _d, _m, d, m in cands:
            if d.id in used or m.id in used:
                continue
            used.update((d.id, m.id))
            out.append((d, m))
    return out


def main() -> None:
    apply = "--apply" in sys.argv
    with Session(engine) as session:
        found = pairs(session)
        for d, m in found:
            print(f"{'SLUČUJI' if apply else 'našel'}: {m.title!r} MB {m.release_date} <- Deezer {d.release_date} ({d.id[:8]} -> {m.id[:8]})")
            if apply:
                dedupe.merge_release(session, d, m)
                session.commit()
    print(f"dvojčat: {len(found)}" + ("" if apply else " (zkouška, --apply provede)"))


if __name__ == "__main__":
    main()
