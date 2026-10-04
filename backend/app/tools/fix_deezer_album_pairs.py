"""Opraví Deezer id přilepené ke stejnojmennému albu špatného typu.

Dřív `ingest_album` párovalo jen podle názvu, takže Deezer ALBUM "The Bends"
(12 skladeb) dostalo MB SINGL "The Bends" (3 skladby) a skladby alba
z hledání se pak zakládaly na singlu (album na stránce chybělo, singl měl
9 skladeb). Tady se:
- najdou alba s Deezer id, k nimž existuje stejnojmenné album téhož
  interpreta opačného typu (album/kompilace vs singl/EP) bez Deezer id,
- ověří se, že Deezer id patří tomu druhému: s `--deezer` podle Deezeru
  (record_type, nb_tracks), jinak podle skladeb -- na řádku visí skladby
  z Deezeru, které jsou jen v tracklistu toho druhého (směr singl -> album),
- Deezer id se přesune a s ním skladby bez MBID, které patří jen druhému
  albu (mimo tracklist původního). Kopie téže nahrávky (stejný název,
  délka +-3 s) se sloučí přes app/maintenance/dedupe.py, ostatní se jen
  přesunou -- nic se nemaže. Řádek jen z Deezeru (bez MBID) se do MB
  řádku sloučí celý (`merge_release`), je to tatáž deska.

    python -m app.tools.fix_deezer_album_pairs [--dry-run] [--deezer]"""
from __future__ import annotations

import asyncio
import sys
from collections import Counter, defaultdict

from sqlmodel import Session, select

from app.catalog.deezer_ingest import _RECORD_TYPE, _tracklist_count, _type_class, album_key, pick_album_match, release_class
from app.db import engine
from app.maintenance import dedupe
from app.models import Recording, Release


def _skip(rel: Release) -> bool:
    refs = rel.external_refs or {}
    return refs.get("source") in ("youtube", "soundcloud", "manual") or (rel.deezer_id or "").startswith("own:")


def _titles(rel: Release) -> set[str]:
    return {dedupe.track_key(t) for t in (rel.external_refs or {}).get("tracklistTitles") or []}


def _strays(session: Session, src: Release, dst: Release) -> list[Recording]:
    """Skladby bez MBID na `src`, které patří jen do tracklistu `dst`."""
    own_ids = set((src.external_refs or {}).get("tracklistIds") or [])
    src_titles, dst_titles = _titles(src), _titles(dst)
    return [
        r for r in session.exec(select(Recording).where(Recording.release_id == src.id)).all()
        if r.mbid is None and r.id not in own_ids
        and (key := dedupe.track_key(r.title)) in dst_titles and key not in src_titles
    ]


async def _deezer_albums(ids: list[str]) -> dict[str, dict]:
    from app.catalog.deezer import DeezerClient

    client = DeezerClient()
    try:
        out = {}
        for dzid in ids:
            data = await client.album(dzid)
            if data:
                out[dzid] = data
        return out
    finally:
        await client.aclose()


def main(dry: bool, use_deezer: bool) -> None:
    skipped: Counter = Counter()
    plans: list[tuple[Release, Release, list[Recording], str]] = []
    with Session(engine) as session:
        by_key: dict[tuple, list[Release]] = defaultdict(list)
        for rel in session.exec(select(Release)).all():
            by_key[(rel.artist_id, album_key(rel.title))].append(rel)
        pairs: list[tuple[Release, list[Release]]] = []
        for rels in by_key.values():
            if len(rels) < 2:
                continue
            for rel in rels:
                cls = release_class(rel)
                if not rel.deezer_id or _skip(rel) or cls is None:
                    continue
                other = [
                    o for o in rels
                    if o.id != rel.id and o.deezer_id is None and release_class(o) not in (None, cls)
                ]
                if other:
                    pairs.append((rel, other))
        dz_info = asyncio.run(_deezer_albums([r.deezer_id for r, _ in pairs])) if use_deezer else {}

        for rel, others in pairs:
            cls = release_class(rel)
            dz = dz_info.get(rel.deezer_id)
            if dz is not None:
                dz_class = _type_class(_RECORD_TYPE.get(dz.get("record_type") or ""))
                if dz_class in (None, cls):
                    skipped["Deezer typ sedí"] += 1
                    continue
                target = pick_album_match(others, dz)
                why = f"Deezer {dz.get('record_type')}, {dz.get('nb_tracks')} skladeb"
            else:
                if use_deezer:
                    skipped["Deezer nedostupný"] += 1
                    continue
                # Bez Deezeru jen směr singl/EP -> album: skladby alba z
                # Deezeru visí na singlu a singl má zjevně málo skladeb.
                if cls != "short":
                    skipped["album -> singl jen s --deezer"] += 1
                    continue
                target = None
                for o in sorted(others, key=lambda o: -(_tracklist_count(o) or 0)):
                    count, own = _tracklist_count(o), _tracklist_count(rel)
                    extra = [r for r in _strays(session, rel, o) if r.deezer_id]
                    if extra and count and count >= 7 and (own or 0) <= 4:
                        target, why = o, f"{len(extra)} Deezer skladeb jen z alba ({own} vs {count} skladeb)"
                        break
                if target is None:
                    skipped["bez důkazu"] += 1
                    continue
            if target is None:
                skipped["žádný cíl"] += 1
                continue
            plans.append((rel, target, _strays(session, rel, target), why))

        print(f"Deezer id k přesunu: {len(plans)}, skladeb k přesunu: {sum(len(p[2]) for p in plans)}, "
              f"kandidátů: {len(pairs)}, přeskočeno: {dict(skipped)}")
        for src, dst, recs, why in plans[:20]:
            print(f"  '{src.title}' dz {src.deezer_id}: {src.release_type} {src.id[:8]} ({src.release_date}) -> "
                  f"{dst.release_type} {dst.id[:8]} ({dst.release_date}); {why}; skladby: {[r.title for r in recs][:6]}")
        if dry:
            print("(nanečisto)")
            return
        moved: Counter = Counter()
        for src, dst, recs, _why in plans:
            if src.mbid is None and dst.mbid is not None:
                # Řádek jen z Deezeru (výchozí typ "album") je tatáž deska
                # jako MB řádek -- skutečný duplikát, sloučit celý.
                dedupe.merge_release(session, src, dst)
                moved["alb sloučeno"] += 1
                continue
            dzid = src.deezer_id
            src.deezer_id = None
            session.add(src)
            session.flush()
            dst.deezer_id = dzid
            session.add(dst)
            dst_recs = {
                dedupe.track_key(r.title): r
                for r in session.exec(select(Recording).where(Recording.release_id == dst.id)).all()
            }
            for rec in recs:
                twin = dst_recs.get(dedupe.track_key(rec.title))
                # Sloučit jen opravdu tutéž nahrávku (délka +-3 s, ne jiná Deezer kopie).
                same = (
                    twin is not None and twin.id != rec.id and twin.deezer_id in (None, rec.deezer_id)
                    and rec.duration_ms and twin.duration_ms and abs(rec.duration_ms - twin.duration_ms) <= 3000
                )
                if same:
                    dedupe.merge_recording(session, rec, twin)
                    moved["sloučeno"] += 1
                else:
                    rec.release_id = dst.id
                    session.add(rec)
                    moved["přesunuto"] += 1
            session.flush()
        session.commit()
        print("hotovo:", dict(moved), dict(dedupe.stats))


if __name__ == "__main__":
    main("--dry-run" in sys.argv, "--deezer" in sys.argv)
