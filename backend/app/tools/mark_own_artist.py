"""Označí interpreta jako VLASTNÍHO (hudba z vlastních souborů, na
MusicBrainz/Deezeru není -- tátova kapela Kontrast) a oddělí od něj, co se
na něj omylem napárovalo ze stejnojmenných cizích kapel.

- Vlastní = alba a skladby s vlastními soubory (MediaAsset z knihovny PC).
- Všechno ostatní (cizí alba z Deezeru, jejich skladby) se přesune na nový
  samostatný řádek stejného jména, který převezme i cizí MBID/Deezer id/fotku.
- Vlastní interpret, jeho alba a skladby dostanou id `own:<id>` (viz
  app/catalog/identity.py) -- MusicBrainz, Deezer, ISRC, Spotify i Apple
  Music -- takže se nikdy s nikým nespárují a nic je nepřepíše.

    python -m app.tools.mark_own_artist <artist_id> [--dry-run]
"""

from __future__ import annotations

import sys

from sqlmodel import Session, select

from app.catalog.identity import OWN_PREFIX, is_own_id
from app.db import engine
from app.models import Artist, MediaAsset, Recording, Release

_OWN_PROVIDERS = ("local", "musicbrainz-local")


def _has_own_file(session: Session, recording_id: str) -> bool:
    return (
        session.exec(
            select(MediaAsset).where(
                MediaAsset.recording_id == recording_id,
                MediaAsset.source_provider.in_(_OWN_PROVIDERS),  # type: ignore[union-attr]
            )
        ).first()
        is not None
    )


def _fake_refs(row_id: str) -> dict:
    """Zástupná id i pro Spotify a Apple Music (import, sdílecí odkazy)."""
    own = f"{OWN_PREFIX}{row_id}"
    return {"spotifyId": own, "appleMusicId": own}


def mark_own(artist_id: str, dry_run: bool = False) -> dict:
    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None:
            raise SystemExit(f"interpret {artist_id} neexistuje")
        recordings = session.exec(select(Recording).where(Recording.artist_id == artist.id)).all()
        own_recs = {r.id for r in recordings if _has_own_file(session, r.id)}
        releases = session.exec(select(Release).where(Release.artist_id == artist.id)).all()
        own_rels = {r.release_id for r in recordings if r.id in own_recs and r.release_id}
        foreign_rels = [r for r in releases if r.id not in own_rels]
        foreign_recs = [r for r in recordings if r.id not in own_recs]
        report = {
            "artist": artist.name,
            "ownReleases": [r.title for r in releases if r.id in own_rels],
            "ownRecordings": len(own_recs),
            "foreignReleases": len(foreign_rels),
            "foreignRecordings": len(foreign_recs),
            "foreignIds": {"mbid": artist.mbid, "deezer": artist.deezer_id},
        }
        if dry_run:
            return report

        # Cizí kapela jako samostatný interpret (převezme cizí id a fotku).
        foreign = None
        if foreign_rels or foreign_recs or (artist.mbid and not is_own_id(artist.mbid)):
            foreign = Artist(name=artist.name, sort_name=artist.sort_name, images=list(artist.images or []))
            session.add(foreign)
            session.flush()
            report["foreignArtistId"] = foreign.id
        old_mbid, old_dz = artist.mbid, artist.deezer_id
        refs = {k: v for k, v in (artist.external_refs or {}).items() if k in ("notMine",)}
        artist.mbid = f"{OWN_PREFIX}{artist.id}"
        artist.deezer_id = f"{OWN_PREFIX}{artist.id}"
        artist.images = []  # cizí fotka; obal alba se ukáže místo ní
        artist.external_refs = {**refs, "ownArtist": True, **_fake_refs(artist.id)}
        session.add(artist)
        session.flush()  # uvolnit unikátní MBID dřív, než ho dostane `foreign`
        if foreign is not None:
            foreign.mbid = old_mbid if old_mbid and not is_own_id(old_mbid) else None
            foreign.deezer_id = old_dz if old_dz and not is_own_id(old_dz) else None
            session.add(foreign)
            for rel in foreign_rels:
                rel.artist_id = foreign.id
                session.add(rel)
            for rec in foreign_recs:
                rec.artist_id = foreign.id
                session.add(rec)
        for rel in releases:
            if rel.id in own_rels:
                rel.mbid = rel.mbid if is_own_id(rel.mbid) else f"{OWN_PREFIX}{rel.id}"
                rel.deezer_id = f"{OWN_PREFIX}{rel.id}"
                rel.external_refs = {**(rel.external_refs or {}), **_fake_refs(rel.id)}
                session.add(rel)
        # Všechny skladby vlastních alb (i hosté / sólo člen, např. "Ikarův pád").
        album_recs = session.exec(select(Recording).where(Recording.release_id.in_(own_rels))).all() if own_rels else []  # type: ignore[union-attr]
        own_recs |= {r.id for r in album_recs}
        by_id = {r.id: r for r in [*recordings, *album_recs]}
        for rec in by_id.values():
            if rec.id in own_recs:
                rec.mbid = rec.mbid if is_own_id(rec.mbid) else f"{OWN_PREFIX}{rec.id}"
                rec.deezer_id = f"{OWN_PREFIX}{rec.id}"
                rec.isrc = f"{OWN_PREFIX}{rec.id}"  # i případné cizí ISRC z doplňování pryč
                rec.external_refs = {**(rec.external_refs or {}), **_fake_refs(rec.id)}
                session.add(rec)
        session.commit()
        return report


if __name__ == "__main__":
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    print(mark_own(args[0], dry_run="--dry-run" in sys.argv))
