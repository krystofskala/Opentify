"""Sloučení duplicitních interpretů (a s nimi alb a skladeb).

Dva zdroje duplicit (opravené v `library/matching.py` a `catalog/upsert.py`):
  1. víc-hodnotové tagy souborů: "Danny Vera;The Rosenberg Trio" byl
     samostatný interpret -> druhá kopie skladby i alba,
  2. stejné jméno bez MBID zakládané znovu a znovu ("RM, Youjeen" 19x).

Pravidla:
  - "A;B" se slučuje do "A" (existuje-li, jinak se jen přejmenuje),
  - stejné jméno: do jediného interpreta s MBID; mají-li MBID dva a víc
    různých (různé kapely "Nirvana"), NIC se neslučuje,
  - alba stejného názvu u téhož interpreta se sloučí, skladby stejného
    názvu na témže albu (nebo bez alba) taky.

Při slučování skladby se převede všechno, co na ni odkazuje: stažený
soubor (MediaAsset), fronta stahování, položky playlistů (vč. oblíbených),
poslechy a "Poslechnout později". Nic se nemaže z disku.

Spuštění: `python -m app.maintenance.dedupe [--apply]` (bez --apply jen
spočítá, co by se stalo).
"""

from __future__ import annotations

import sys
from collections import Counter, defaultdict

from sqlalchemy import delete, func, update
from sqlmodel import Session, select

from app.db import engine
from app.models import (
    Artist,
    Listen,
    ListenLater,
    MediaAsset,
    MediaAssetStatus,
    PlaylistItem,
    ProvisioningJob,
    Recording,
    Release,
)

stats: Counter = Counter()


def _norm(text: str) -> str:
    return " ".join(text.lower().split())


def merge_recording(session: Session, src: Recording, dst: Recording) -> None:
    src_asset = session.get(MediaAsset, src.id)
    dst_asset = session.get(MediaAsset, dst.id)
    if src_asset is not None:
        keep_src = dst_asset is None or (
            dst_asset.status != MediaAssetStatus.AVAILABLE and src_asset.status == MediaAssetStatus.AVAILABLE
        )
        if keep_src:
            if dst_asset is not None:
                session.delete(dst_asset)
                session.flush()
            session.execute(update(MediaAsset).where(MediaAsset.recording_id == src.id).values(recording_id=dst.id))
        else:
            session.delete(src_asset)
        stats["assets"] += 1
    session.execute(update(ProvisioningJob).where(ProvisioningJob.recording_id == src.id).values(recording_id=dst.id))
    # Položky playlistů: v playlistu, kde už cílová skladba je, zdroj jen smazat.
    for item in session.exec(select(PlaylistItem).where(PlaylistItem.recording_id == src.id)).all():
        exists = session.exec(
            select(PlaylistItem.id).where(PlaylistItem.playlist_id == item.playlist_id, PlaylistItem.recording_id == dst.id)
        ).first()
        if exists:
            session.delete(item)
        else:
            item.recording_id = dst.id
            session.add(item)
        stats["playlist_items"] += 1
    moved = session.execute(update(Listen).where(Listen.recording_id == src.id).values(recording_id=dst.id))
    stats["listens"] += moved.rowcount or 0
    _move_later(session, "track", src.id, dst.id)
    # Doplnit, co cílové chybí (MBID je unikátní -- nejdřív uvolnit).
    refs = dict(dst.external_refs or {})
    for key, value in (src.external_refs or {}).items():
        refs.setdefault(key, value)
    dst.external_refs = refs
    if dst.mbid is None and src.mbid:
        mbid = src.mbid
        src.mbid = None
        session.add(src)
        session.flush()
        dst.mbid = mbid
    dst.duration_ms = dst.duration_ms or src.duration_ms
    dst.isrc = dst.isrc or src.isrc
    dst.deezer_id = dst.deezer_id or src.deezer_id
    session.add(dst)
    session.delete(src)
    session.flush()
    stats["recordings_merged"] += 1


def _move_later(session: Session, kind: str, src_id: str, dst_id: str) -> None:
    for item in session.exec(select(ListenLater).where(ListenLater.kind == kind, ListenLater.target_id == src_id)).all():
        dup = session.exec(
            select(ListenLater).where(
                ListenLater.user_id == item.user_id, ListenLater.kind == kind, ListenLater.target_id == dst_id
            )
        ).first()
        if dup:
            session.delete(item)
        else:
            item.target_id = dst_id
            session.add(item)


def merge_release(session: Session, src: Release, dst: Release) -> None:
    # Skladby: stejný název na cílovém albu -> sloučit, jinak přesunout.
    dst_titles = {
        _norm(r.title): r for r in session.exec(select(Recording).where(Recording.release_id == dst.id)).all()
    }
    for rec in session.exec(select(Recording).where(Recording.release_id == src.id)).all():
        twin = dst_titles.get(_norm(rec.title))
        if twin is not None and twin.id != rec.id:
            merge_recording(session, rec, twin)
        else:
            rec.release_id = dst.id
            rec.artist_id = dst.artist_id if rec.artist_id == src.artist_id else rec.artist_id
            session.add(rec)
    _move_later(session, "album", src.id, dst.id)
    dst.images = dst.images or src.images
    dst.genres = dst.genres or src.genres
    dst.release_date = dst.release_date or src.release_date
    dst.deezer_id = dst.deezer_id or src.deezer_id
    if dst.mbid is None and src.mbid:
        mbid = src.mbid
        src.mbid = None
        session.add(src)
        session.flush()
        dst.mbid = mbid
    session.add(dst)
    session.delete(src)
    session.flush()
    stats["releases_merged"] += 1


def merge_artist(session: Session, src: Artist, dst: Artist) -> None:
    dst_releases = {_norm(r.title): r for r in session.exec(select(Release).where(Release.artist_id == dst.id)).all()}
    for rel in session.exec(select(Release).where(Release.artist_id == src.id)).all():
        twin = dst_releases.get(_norm(rel.title))
        if twin is not None:
            merge_release(session, rel, twin)
        else:
            rel.artist_id = dst.id
            session.add(rel)
            dst_releases[_norm(rel.title)] = rel
    session.flush()
    # Skladby interpreta mimo jeho alba (nebo na albech jiných interpretů).
    dst_loose = defaultdict(dict)
    for r in session.exec(select(Recording).where(Recording.artist_id == dst.id)).all():
        dst_loose[r.release_id][_norm(r.title)] = r
    for rec in session.exec(select(Recording).where(Recording.artist_id == src.id)).all():
        twin = dst_loose[rec.release_id].get(_norm(rec.title)) or (
            dst_loose[None].get(_norm(rec.title)) if rec.release_id is None else None
        )
        if twin is not None and twin.id != rec.id:
            merge_recording(session, rec, twin)
        else:
            rec.artist_id = dst.id
            session.add(rec)
    _move_later(session, "artist", src.id, dst.id)
    dst.images = dst.images or src.images
    dst.deezer_id = dst.deezer_id or src.deezer_id
    refs = dict(dst.external_refs or {})
    for key, value in (src.external_refs or {}).items():
        refs.setdefault(key, value)
    dst.external_refs = refs
    if dst.mbid is None and src.mbid:
        mbid = src.mbid
        src.mbid = None
        session.add(src)
        session.flush()
        dst.mbid = mbid
    session.add(dst)
    session.delete(src)
    session.flush()
    stats["artists_merged"] += 1


def _recording_count(session: Session, artist_id: str) -> int:
    return session.exec(select(func.count()).select_from(Recording).where(Recording.artist_id == artist_id)).one()


def run(apply: bool) -> Counter:
    with Session(engine) as session:
        # 1) "A;B" -> "A"
        for artist in session.exec(select(Artist).where(Artist.name.contains(";"))).all():  # type: ignore[attr-defined]
            primary = artist.name.split(";")[0].strip()
            if not primary:
                continue
            target = session.exec(
                select(Artist).where(func.lower(Artist.name) == primary.lower(), Artist.id != artist.id)
            ).all()
            target.sort(key=lambda a: (a.mbid is None, -_recording_count(session, a.id)))
            if target:
                merge_artist(session, artist, target[0])
            else:
                artist.name = primary
                artist.sort_name = primary
                session.add(artist)
                stats["artists_renamed"] += 1
        session.flush()

        # 2) Stejné jméno.
        groups: dict[str, list[Artist]] = defaultdict(list)
        for artist in session.exec(select(Artist)).all():
            groups[artist.name.strip().lower()].append(artist)
        for name, rows in groups.items():
            if len(rows) < 2:
                continue
            mbids = {a.mbid for a in rows if a.mbid}
            if len(mbids) > 1:
                stats["groups_skipped_ambiguous"] += 1
                continue
            rows.sort(key=lambda a: (a.mbid is None, a.deezer_id is None, -_recording_count(session, a.id)))
            keep = rows[0]
            for other in rows[1:]:
                merge_artist(session, other, keep)

        # 3) Stejně pojmenovaná alba jednoho interpreta (i bez duplicit interpretů).
        by_key: dict[tuple[str, str], list[Release]] = defaultdict(list)
        for rel in session.exec(select(Release)).all():
            by_key[(rel.artist_id, _norm(rel.title))].append(rel)
        for rows in by_key.values():
            if len(rows) < 2:
                continue
            mbids = {r.mbid for r in rows if r.mbid}
            if len(mbids) > 1:
                continue  # různé edice s vlastním MBID -- nechat
            rows.sort(key=lambda r: (r.mbid is None, not r.images))
            for other in rows[1:]:
                merge_release(session, other, rows[0])

        if apply:
            session.commit()
        else:
            session.rollback()
    return stats


if __name__ == "__main__":
    apply = "--apply" in sys.argv
    result = run(apply)
    print(("POUŽITO" if apply else "ZKUŠEBNĚ (nic neuloženo)"), dict(result))
