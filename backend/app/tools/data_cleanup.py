"""Bezpečný úklid dat (audit 2026-10-02). Vždy nejdřív --dry-run.

    python -m app.tools.data_cleanup [--dry-run]

1. "placeholder" soubory (20 KB atrapy z vývoje) jako AVAILABLE -> stáhnout znovu,
2. položky playlistů, jejichž playlist už neexistuje -> pryč,
3. duplicitní LibraryEntry (profil + skladba) -> nechat nejstarší,
4. duplicitní poslechy (profil + skladba + čas) -> nechat jeden,
5. prázdné "Oblíbené" smazaných profilů -> pryč,
6. zastaralý zdroj (soubor ze Soulseeku, ale sourceKey/youtubeUrl z YouTube),
7. osiřelé soubory v /data/media (nikdo na ně neodkazuje) -> do karantény
   /data/media/_quarantine (smazat ručně za týden).
"""

from __future__ import annotations

import asyncio
import shutil
import sys
from collections import defaultdict
from pathlib import Path

from sqlmodel import Session, select

from app.auth import ADMIN_ID
from app.db import engine
from app.models import (
    AppUser,
    LibraryEntry,
    Listen,
    MediaAsset,
    MediaAssetStatus,
    Playlist,
    PlaylistItem,
    Recording,
)

MEDIA = Path("/data/media")
QUARANTINE = MEDIA / "_quarantine"


async def main(dry: bool) -> None:
    from app.provisioning_service import enqueue, get_or_create_job

    requeue: list[str] = []
    with Session(engine) as s:
        # 1
        ph = s.exec(select(MediaAsset).where(MediaAsset.source_provider == "placeholder")).all()
        print(f"1) placeholder souborů: {len(ph)}")
        for a in ph:
            if not dry:
                a.status = MediaAssetStatus.MISSING
                a.storage_path = None
                a.source_provider = None
                s.add(a)
            requeue.append(a.recording_id)

        # 2
        playlist_ids = set(s.exec(select(Playlist.id)).all())
        orphan_items = [i for i in s.exec(select(PlaylistItem)).all() if i.playlist_id not in playlist_ids]
        print(f"2) položek bez playlistu: {len(orphan_items)}")
        if not dry:
            for i in orphan_items:
                s.delete(i)

        # 3
        seen: dict[tuple[str, str], LibraryEntry] = {}
        dup_entries = []
        for e in sorted(s.exec(select(LibraryEntry)).all(), key=lambda e: e.added_at):
            key = (e.user_id, e.recording_id)
            if key in seen:
                dup_entries.append(e)
            else:
                seen[key] = e
        print(f"3) duplicitní LibraryEntry: {len(dup_entries)}")
        if not dry:
            for e in dup_entries:
                s.delete(e)

        # 4
        groups: dict[tuple, list[Listen]] = defaultdict(list)
        for listen in s.exec(select(Listen).where(Listen.source == "spotify-history")).all():
            groups[(listen.user_id, listen.recording_id, listen.played_at)].append(listen)
        dup_listens = [x for g in groups.values() for x in g[1:]]
        print(f"4) duplicitní poslechy: {len(dup_listens)}")
        if not dry:
            for x in dup_listens:
                s.delete(x)

        # 5
        users = set(s.exec(select(AppUser.id)).all()) | {ADMIN_ID}
        dead = [
            p
            for p in s.exec(select(Playlist).where(Playlist.source == "liked-songs")).all()
            if p.owner_user_id not in users
            and not s.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == p.id)).first()
        ]
        print(f"5) prázdné Oblíbené smazaných profilů: {len(dead)}")
        if not dry:
            for p in dead:
                s.delete(p)

        # 6
        stale = 0
        for a in s.exec(select(MediaAsset).where(MediaAsset.source_provider == "slskd")).all():
            rec = s.get(Recording, a.recording_id)
            refs = dict((rec.external_refs or {}) if rec else {})
            if rec is None:
                continue
            if str(refs.get("sourceKey") or "").startswith("youtube:") or refs.get("youtubeUrl"):
                stale += 1
                if not dry:
                    if str(refs.get("sourceKey") or "").startswith("youtube:"):
                        refs.pop("sourceKey", None)
                    refs.pop("youtubeUrl", None)
                    rec.external_refs = refs
                    s.add(rec)
        print(f"6) zastaralý zdroj u souborů ze Soulseeku: {stale}")

        # 7
        referenced = {Path(p).name for p in s.exec(select(MediaAsset.storage_path)).all() if p}
        recording_ids = None  # noqa: F841
        orphans = []
        for f in MEDIA.iterdir():
            if f.is_dir():
                continue
            if f.name in referenced:
                continue
            # rozpracované stahování (.part) nechat, jen staré
            orphans.append(f)
        # Nesahat na soubory skladeb, které se právě stahují.
        downloading = {
            a.recording_id
            for a in s.exec(select(MediaAsset).where(MediaAsset.status != MediaAssetStatus.AVAILABLE)).all()
        }
        orphans = [f for f in orphans if f.name.split(".")[0].split("_")[0] not in downloading]
        size = sum(f.stat().st_size for f in orphans)
        print(f"7) osiřelých souborů: {len(orphans)} ({size / 1e6:.0f} MB) -> karanténa")
        if not dry:
            QUARANTINE.mkdir(exist_ok=True)
            for f in orphans:
                shutil.move(str(f), str(QUARANTINE / f.name))

        if not dry:
            s.commit()

    if not dry:
        with Session(engine) as s:
            for rid in requeue:
                _a, job, created = get_or_create_job(s, rid, ADMIN_ID, None)
                if job is not None and created:
                    await enqueue(job)
        print(f"znovu stahuji {len(requeue)} skladeb")
    print("hotovo" + (" (nanečisto)" if dry else ""))


if __name__ == "__main__":
    asyncio.run(main("--dry-run" in sys.argv))
