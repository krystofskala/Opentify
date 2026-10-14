"""Oprava identity interpretů po chybných sloučeních (14. 10. 2026).

    python -m app.tools.fix_artist_identity                 # zkušební běh (nic nemění)
    python -m app.tools.fix_artist_identity --apply         # provede, se zálohou

1. Alba jmenovce pod slavným (8f+): alba, která na Deezeru patří jinému
   interpretovi, jehož řádek u nás existuje jako samostatný jmenovec (bez
   `mergedInto`), se i se skladbami přesunou zpět na jeho řádek. Kompilace
   (vlastník je třetí strana, např. soundtrack) zůstávají. Přesouvá se JEN
   u interpretů z `--only NAME` (zkušební běh ukázal, že stejné pravidlo
   chytá i duplicitní profily téhož interpreta – Nobuo Uematsu), ostatní
   se jen vypíšou.
2. Slabý Deezer profil hlavního řádku (8i): hlavní řádek nese Deezer id
   sloučeného duplikátu s mnohem méně fanoušky a alby -> přepnout na silnější
   profil duplikátu (duplikát si nechá své id jako alias). Jen když má silnější
   profil aspoň 10× víc fanoušků a víc alb; `--skip NAME` vynechá interpreta
   (např. Appleseed, kde není jisté, že jde o stejnou kapelu).

Záloha změněných řádků: /data/db/backups/fix-artist-identity-<čas>.json
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
from datetime import datetime

from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.db import engine
from app.models import Artist, Recording, Release


async def _album_owner(dz, album_id: str) -> str | None:
    try:
        album = await dz._get(f"/album/{album_id}", {})
    except Exception:  # noqa: BLE001
        return None
    owner = ((album or {}).get("artist") or {}).get("id")
    return str(owner) if owner else None


async def _artist(dz, cache: dict, dz_id: str) -> dict:
    if dz_id not in cache:
        try:
            cache[dz_id] = await dz._get(f"/artist/{dz_id}", {}) or {}
        except Exception:  # noqa: BLE001
            cache[dz_id] = {}
    return cache[dz_id]


async def plan(skip: set[str]) -> dict:
    dz = get_deezer_client()
    cache: dict = {}
    moves, switches = [], []
    with Session(engine) as s:
        artists = s.exec(select(Artist)).all()
        by_dz = {a.deezer_id: a for a in artists if a.deezer_id and not (a.external_refs or {}).get("mergedInto")}
        # 1) alba jmenovce pod jiným řádkem stejného jména
        names: dict[str, list[Artist]] = {}
        for a in artists:
            if not (a.external_refs or {}).get("mergedInto"):
                names.setdefault(a.name.casefold(), []).append(a)
        for group in names.values():
            if len(group) < 2:
                continue
            for a in group:
                for rel in s.exec(select(Release).where(Release.artist_id == a.id, Release.deezer_id.is_not(None))).all():
                    owner = await _album_owner(dz, rel.deezer_id)
                    if not owner or owner == a.deezer_id:
                        continue
                    target = by_dz.get(owner)
                    if target is not None and target.id != a.id and target.name.casefold() == a.name.casefold():
                        recs = s.exec(select(Recording.id).where(Recording.release_id == rel.id, Recording.artist_id == a.id)).all()
                        moves.append({"release": rel.id, "title": rel.title, "from": a.id, "to": target.id, "name": a.name, "recordings": list(recs)})
        # 2) slabý Deezer profil hlavního řádku
        for dup in artists:
            canon_id = (dup.external_refs or {}).get("mergedInto")
            if not canon_id or not dup.deezer_id:
                continue
            canon = s.get(Artist, canon_id)
            if canon is None or not canon.deezer_id or canon.deezer_id == dup.deezer_id or canon.name in skip:
                continue
            a, b = await _artist(dz, cache, dup.deezer_id), await _artist(dz, cache, canon.deezer_id)
            fa, fb = int(a.get("nb_fan") or 0), int(b.get("nb_fan") or 0)
            na, nb = int(a.get("nb_album") or 0), int(b.get("nb_album") or 0)
            if fa >= 10 * max(fb, 1) and na > nb:
                switches.append({"artist": canon.id, "name": canon.name, "from_dz": canon.deezer_id, "to_dz": dup.deezer_id, "fans": [fb, fa]})
    return {"moves": moves, "switches": switches}


def apply(p: dict) -> str:
    os.makedirs("/data/db/backups", exist_ok=True)
    path = f"/data/db/backups/fix-artist-identity-{datetime.now():%Y%m%d-%H%M%S}.json"
    with Session(engine) as s:
        backup = {"releases": {}, "recordings": {}, "artists": {}}
        for m in p["moves"]:
            rel = s.get(Release, m["release"])
            backup["releases"][rel.id] = rel.artist_id
            rel.artist_id = m["to"]
            s.add(rel)
            for rid in m["recordings"]:
                rec = s.get(Recording, rid)
                backup["recordings"][rec.id] = rec.artist_id
                rec.artist_id = m["to"]
                s.add(rec)
        for sw in p["switches"]:
            art = s.get(Artist, sw["artist"])
            backup["artists"][art.id] = {"deezer_id": art.deezer_id, "images": art.images}
            art.deezer_id = sw["to_dz"]
            art.images = []  # fotka se dohledá znovu z nového profilu
            s.add(art)
        json.dump(backup, open(path, "w"), ensure_ascii=False, indent=1)
        s.commit()
    return path


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    ap.add_argument("--skip", action="append", default=[])
    ap.add_argument("--only", action="append", default=[], help="přesunout alba jen u těchto interpretů")
    args = ap.parse_args()
    p = asyncio.run(plan(set(args.skip)))
    only = {n.casefold() for n in args.only}
    listed = p["moves"]
    p["moves"] = [m for m in listed if m["name"].casefold() in only]
    print(f"Alba pod jiným stejnojmenným řádkem: {len(listed)} (přesune se {len(p['moves'])} – jen --only)")
    for m in listed:
        mark = "PŘESUN" if m in p["moves"] else "jen výpis"
        print(f"  [{mark}] {m['name']}: „{m['title']}“ ({len(m['recordings'])} skladeb) {m['from'][:8]} -> {m['to'][:8]}")
    print(f"Přepnutí na silnější Deezer profil: {len(p['switches'])}")
    for sw in p["switches"]:
        print(f"  {sw['name']}: {sw['from_dz']} ({sw['fans'][0]} fanoušků) -> {sw['to_dz']} ({sw['fans'][1]})")
    if args.apply:
        print("Záloha:", apply(p))
    else:
        print("(zkušební běh – nic nezměněno; --apply provede)")


if __name__ == "__main__":
    main()
