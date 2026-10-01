"""Opraví interprety, kteří mají cizí fotku: stejný obrázek u víc interpretů
s různým Deezer id (fotka přišla z hledání podle jména). Každý z nich dostane
fotku svého vlastního Deezer profilu.

    python -m app.tools.fix_shared_artist_photos [--dry-run]
"""

from __future__ import annotations

import asyncio
import sys
from collections import defaultdict

from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.deezer_ingest import deezer_image, is_placeholder_picture
from app.catalog.identity import is_own_id
from app.db import engine
from app.models import Artist


async def main(dry_run: bool) -> None:
    with Session(engine) as session:
        by_image: dict[str, list[Artist]] = defaultdict(list)
        for a in session.exec(select(Artist)).all():
            if a.images and not (a.external_refs or {}).get("mergedInto"):
                by_image[a.images[0]].append(a)
        suspects = [
            (a.id, a.name, a.deezer_id)
            for group in by_image.values()
            if len({a.deezer_id for a in group if a.deezer_id}) > 1
            for a in group
            if a.deezer_id and not is_own_id(a.mbid)
        ]
    dz = get_deezer_client()
    fixed = 0
    for artist_id, name, deezer_id in suspects:
        data = await dz.artist(deezer_id)
        picture = deezer_image((data or {}).get("picture_xl") or (data or {}).get("picture_big"))
        with Session(engine) as session:
            artist = session.get(Artist, artist_id)
            if artist is None:
                continue
            new = [picture] if picture and not is_placeholder_picture(picture) else []
            # Bez vlastní fotky (spolupráce "A feat. B") nechat tu sdílenou.
            if not new or new == (artist.images or []):
                continue
            print(f"{name} ({deezer_id}): {artist.images[:1]} -> {new}")
            fixed += 1
            if not dry_run:
                artist.images = new
                session.add(artist)
                session.commit()
    print(f"suspects={len(suspects)} changed={fixed} dry_run={dry_run}")


if __name__ == "__main__":
    asyncio.run(main("--dry-run" in sys.argv))
