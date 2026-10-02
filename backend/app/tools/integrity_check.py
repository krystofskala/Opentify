"""Kontrolní součty před/po úklidu: počty v knihovně a Oblíbených každého
profilu, stažené soubory, poslechy a odkazy na neexistující skladby.

    python -m app.tools.integrity_check
"""

from __future__ import annotations

from sqlmodel import Session, func, select

from app.db import engine
from app.models import (
    AppUser,
    HeardFully,
    LibraryEntry,
    Listen,
    MediaAsset,
    MediaAssetStatus,
    Playlist,
    PlaylistItem,
    Recording,
)


def snapshot() -> dict[str, int]:
    out: dict[str, int] = {}
    with Session(engine) as s:
        rec_ids = set(s.exec(select(Recording.id)).all())
        out["available_assets"] = s.exec(
            select(func.count()).select_from(MediaAsset).where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
        ).one()
        out["listens"] = s.exec(select(func.count()).select_from(Listen)).one()
        for u in ["demo-user", *[u.id for u in s.exec(select(AppUser)).all()]]:
            liked = s.exec(
                select(Playlist).where(Playlist.owner_user_id == u, Playlist.source == "liked-songs")
            ).first()
            if liked is not None:
                out[f"liked:{u[:8]}"] = s.exec(
                    select(func.count()).select_from(PlaylistItem).where(PlaylistItem.playlist_id == liked.id)
                ).one()
            out[f"library_entries:{u[:8]}"] = s.exec(
                select(func.count()).select_from(LibraryEntry).where(LibraryEntry.user_id == u)
            ).one()
        dangling = 0
        for model in (PlaylistItem, LibraryEntry, Listen, HeardFully):
            for rid in s.exec(select(model.recording_id)).all():
                if rid not in rec_ids:
                    dangling += 1
        out["dangling_refs"] = dangling
        out["dangling_assets"] = sum(1 for rid in s.exec(select(MediaAsset.recording_id)).all() if rid not in rec_ids)
    return out


if __name__ == "__main__":
    for k, v in snapshot().items():
        print(f"{k}: {v}")
