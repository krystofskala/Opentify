"""Doplní katalogu verzi z MusicBrainz (DQ5), aby stahování vědělo, že má
hledat živou / demo / akustickou verzi i tam, kde to název neříká.

1. Typ vydání (`mbSecondary`: live, demo, remix...) -- jedno procházení
   diskografie na interpreta (živé album bez "live" v názvu, "Stop Making
   Sense", stahovalo studiovky).
2. Poznámka u nahrávky (`mbDisambiguation`: "live, 1994-05-02: ...") a stav
   vydání (`mbStatuses`: official / bootleg / promotion) -- jeden dotaz na
   vydání.

Nic nevytváří ani neskrývá, jen doplňuje `external_refs` existujícím řádkům.
MusicBrainz má jednu frontu pro celou appku (1 dotaz/s) -- mezi dotazy pauza,
ať živé procházení appky nečeká. Pokračuje, kde skončil:
`python -m app.tools.backfill_mb_versions`.
"""

from __future__ import annotations

import asyncio

from sqlmodel import Session, select

from app.catalog.musicbrainz import MusicBrainzError, get_musicbrainz_client
from app.db import engine
from app.models import Artist, Recording, Release

PAUSE_SECONDS = 1.5


def _set_refs(row, **values) -> bool:
    refs = dict(row.external_refs or {})
    new = {**refs, **values}
    if new == refs:
        return False
    row.external_refs = new
    return True


async def backfill_secondary() -> None:
    mb = get_musicbrainz_client()
    with Session(engine) as session:
        missing = [
            r for r in session.exec(select(Release).where(Release.mbid.is_not(None))).all()  # type: ignore[union-attr]
            if "mbSecondary" not in (r.external_refs or {})
        ]
        artist_ids = sorted({r.artist_id for r in missing})
        artists = [(a.id, a.mbid) for a in (session.get(Artist, i) for i in artist_ids) if a and a.mbid]
    print(f"typ vydání: {len(missing)} vydání od {len(artists)} interpretů", flush=True)
    filled = 0
    for n, (artist_id, artist_mbid) in enumerate(artists, 1):
        secondary: dict[str, list[str]] = {}
        offset = 0
        while True:
            try:
                data = await mb.browse_release_groups(artist_mbid, None, 100, offset)
            except MusicBrainzError as exc:
                print(f"  {artist_mbid}: {exc}", flush=True)
                break
            groups = data.get("release-groups") or []
            for rg in groups:
                if rg.get("id"):
                    secondary[rg["id"]] = [t.lower() for t in rg.get("secondary-types") or []]
            offset += len(groups)
            await asyncio.sleep(PAUSE_SECONDS)
            if not groups or offset >= (data.get("release-group-count") or 0):
                break
        with Session(engine) as session:
            for release in session.exec(select(Release).where(Release.artist_id == artist_id)).all():
                if release.mbid in secondary and _set_refs(release, mbSecondary=secondary[release.mbid]):
                    session.add(release)
                    filled += 1
            session.commit()
        if n % 50 == 0:
            print(f"  {n}/{len(artists)} interpretů, doplněno {filled}", flush=True)
    print(f"typ vydání hotovo, doplněno {filled}", flush=True)


async def backfill_tracks() -> None:
    mb = get_musicbrainz_client()
    with Session(engine) as session:
        todo = [
            (r.id, r.mbid)
            for r in session.exec(select(Release).where(Release.mbid.is_not(None))).all()  # type: ignore[union-attr]
            if not (r.external_refs or {}).get("mbTracksChecked")
        ]
    print(f"poznámky nahrávek: {len(todo)} vydání", flush=True)
    notes = 0
    for n, (release_id, rgid) in enumerate(todo, 1):
        try:
            data = await mb.get_release_group_tracks(rgid)
        except MusicBrainzError as exc:
            print(f"  {rgid}: {exc}", flush=True)
            await asyncio.sleep(PAUSE_SECONDS)
            continue
        by_mbid: dict[str, str] = {}
        for rel in data.get("releases") or []:
            for medium in rel.get("media") or []:
                for track in medium.get("tracks") or []:
                    rec = track.get("recording") or {}
                    if rec.get("id") and rec.get("disambiguation"):
                        by_mbid[rec["id"]] = rec["disambiguation"].strip()
        statuses = sorted({(r.get("status") or "").lower() for r in data.get("releases") or []} - {""})
        with Session(engine) as session:
            if by_mbid:
                for rec in session.exec(select(Recording).where(Recording.mbid.in_(list(by_mbid)))).all():  # type: ignore[union-attr]
                    if _set_refs(rec, mbDisambiguation=by_mbid[rec.mbid]):
                        session.add(rec)
                        notes += 1
            release = session.get(Release, release_id)
            if release is not None:
                values = {"mbTracksChecked": True, **({"mbStatuses": statuses} if statuses else {})}
                if _set_refs(release, **values):
                    session.add(release)
            session.commit()
        if n % 200 == 0:
            print(f"  {n}/{len(todo)} vydání, poznámek {notes}", flush=True)
        await asyncio.sleep(PAUSE_SECONDS)
    print(f"poznámky hotovo, doplněno {notes}", flush=True)


async def main() -> None:
    await backfill_secondary()
    await backfill_tracks()


if __name__ == "__main__":
    asyncio.run(main())
