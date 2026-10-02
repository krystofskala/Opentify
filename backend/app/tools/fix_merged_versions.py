"""Rozpojí skladby, do kterých se při ukládání z Deezeru zapsala jiná verze
("Heathens" studiová dostala řádek "Heathens (Live In Mexico City)"): dřív
se párovalo podle názvu bez závorek. Pro každou nahrávku s Deezer id porovná
název u Deezeru s naším (i s verzí v závorce); nesedí-li, Deezer id se
z řádku odebere -- příští hledání/žebříček pak založí správnou nahrávku.

    python -m app.tools.fix_merged_versions [--dry-run] [--from=N]
"""

from __future__ import annotations

import asyncio
import re
import sys

from sqlalchemy.exc import OperationalError
from sqlmodel import Session, select

from app.catalog.deezer import get_deezer_client
from app.catalog.deezer_ingest import version_key
from app.db import engine
from app.models import Recording


_MARKERS = re.compile(
    r"\b(live|remix|mix|acoustic|instrumental|demo|karaoke|unplugged|session|livestream|orchestral|reimagined)\b",
    re.IGNORECASE,
)


def _versions(title: str) -> set[str]:
    """Slova verze ("live", "remix"...) -- "Remastered" verzi nemění."""
    return {m.lower() for m in _MARKERS.findall(title)}


async def main(dry_run: bool) -> None:
    with Session(engine) as session:
        rows = [
            (r.id, r.title, r.deezer_id)
            for r in session.exec(
                select(Recording).where(Recording.deezer_id.is_not(None)).order_by(Recording.id)  # type: ignore[union-attr]
            ).all()
        ]
    print(f"kontroluji {len(rows)} nahrávek", flush=True)
    dz = get_deezer_client()
    fixed = 0
    start = next((int(a.split("=", 1)[1]) for a in sys.argv if a.startswith("--from=")), 0)
    for i, (rec_id, title, dzid) in enumerate(rows):
        if i < start:
            continue
        if i and i % 500 == 0:
            print(f"  {i}/{len(rows)}, opraveno {fixed}", flush=True)
        try:
            track = await dz.track(dzid)
        except Exception:  # noqa: BLE001
            continue
        if not track or not track.get("title"):
            continue
        if version_key(track["title"]) == version_key(title) or _versions(track["title"]) == _versions(title):
            continue
        fixed += 1
        print(f"  {title!r} != Deezer {track['title']!r} ({dzid})", flush=True)
        if dry_run:
            continue
        for attempt in range(10):
            try:
                with Session(engine) as session:
                    rec = session.get(Recording, rec_id)
                    if rec is None:
                        break
                    rec.deezer_id = None
                    refs = dict(rec.external_refs or {})
                    refs.pop("previewUrl", None)  # ukázka byla té druhé verze
                    rec.external_refs = refs
                    session.add(rec)
                    session.commit()
                break
            except OperationalError:
                # DB zamčená jiným zápisem (API, worker) -- chvíli počkat.
                await asyncio.sleep(2 * (attempt + 1))
    print(f"hotovo, rozpojeno {fixed}", flush=True)


if __name__ == "__main__":
    asyncio.run(main("--dry-run" in sys.argv))
