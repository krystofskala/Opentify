"""Přehraje uložená hledání ze slskd (GET /searches) novým výběrem `_rank`
a ukáže, co by se vybralo -- jen čtení, nic se nestahuje.

    python -m app.tools.replay_slskd [--limit N]
"""

from __future__ import annotations

import asyncio
import sys
from collections import Counter

import httpx
from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, Recording
from app.providers import SlskdProvider, TrackMetadata


def _targets() -> dict[str, list[TrackMetadata]]:
    """soulseek_query -> skladby katalogu, které by takové hledání spustily."""
    from app.worker import _album_title

    out: dict[str, list[TrackMetadata]] = {}
    with Session(engine) as s:
        artists = {a.id: a.name for a in s.exec(select(Artist)).all()}
        from app.models import ProvisioningJob

        rec_ids = set(s.exec(select(ProvisioningJob.recording_id)).all())
        for r in s.exec(select(Recording).where(Recording.id.in_(rec_ids))).all():  # type: ignore[attr-defined]
            t = TrackMetadata(
                recording_id=r.id,
                title=r.title,
                artist_name=artists.get(r.artist_id),
                duration_ms=r.duration_ms,
                album_title=_album_title(s, r),
                track_number=r.track_number,
            )
            out.setdefault(t.soulseek_query.lower(), []).append(t)
    return out


async def main(limit: int) -> None:
    slskd = SlskdProvider()
    targets = _targets()
    stats: Counter[str] = Counter()
    async with httpx.AsyncClient(base_url=slskd.base_url, headers=slskd._headers(), timeout=30) as c:
        searches = (await c.get("/api/v0/searches")).json()
        for srch in searches[:limit]:
            tracks = targets.get((srch.get("searchText") or "").lower())
            if not tracks:
                stats["bez skladby"] += 1
                continue
            responses = (await c.get(f"/api/v0/searches/{srch['id']}/responses")).json()
            for track in tracks[:1]:
                ranked = slskd._rank(responses, track, interactive=False)
                stats["vybráno" if ranked else "nic"] += 1
                pick = ranked[0][2]["filename"].replace("\\", "/").split("/")[-2:] if ranked else None
                print(f"{track.artist_name} – {track.title} [{(track.duration_ms or 0)//1000}s] -> {'/'.join(pick) if pick else 'NEMÁME'}", flush=True)
    print(dict(stats))


if __name__ == "__main__":
    n = int(sys.argv[sys.argv.index("--limit") + 1]) if "--limit" in sys.argv else 1000
    asyncio.run(main(n))
