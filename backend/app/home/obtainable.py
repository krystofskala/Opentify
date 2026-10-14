"""Skladby, které se nedají sehnat, do výběrů nepatří (13. 10.: rádio
nabídlo "Are You A Dreamer?" z koncertu "Live at Schubas 2004", nikde
ke stažení, přehrávač stál na chybě).

Nesehnatelná = poslední pokus o stažení skončil FAILED. Nemá lhůtu --
zmizí, až se ji podaří stáhnout (ručně / z alba). Místo ní jiná verze
téže skladby od téhož interpreta, kterou sehnat jde (studiová místo
živé, jiné vydání); když žádná není, vypadne.
"""

from __future__ import annotations

import logging
from typing import Any

from sqlmodel import Session, select

from app.catalog.service import normalize_title
from app.db import engine
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording

logger = logging.getLogger(__name__)

# Kolik nesehnatelných dohledat na Deezeru v jedné várce (každá = 1 hledání).
MAX_LOOKUPS = 5


def _failed(session: Session, ids: list[str]) -> set[str]:
    if not ids:
        return set()
    return set(
        session.exec(
            select(MediaAsset.recording_id).where(
                MediaAsset.recording_id.in_(ids), MediaAsset.status == MediaAssetStatus.FAILED
            )
        ).all()
    )


def _twin(session: Session, recording: Recording, taken: set[str]) -> str | None:
    """Jiná nahrávka téhož interpreta se stejným názvem (bez závorek), která
    neselhala; stažená má přednost."""
    key = normalize_title(recording.title or "")
    if not key or not recording.artist_id:
        return None
    rows = session.exec(
        select(Recording, MediaAsset.status)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id, isouter=True)
        .where(Recording.artist_id == recording.artist_id, Recording.id != recording.id)
    ).all()
    best = None
    for other, status in rows:
        if other.id in taken or status == MediaAssetStatus.FAILED or normalize_title(other.title or "") != key:
            continue
        if status == MediaAssetStatus.AVAILABLE:
            return other.id
        best = best or other.id
    return best


def _replace(ids: list[str], swaps: dict[str, str | None]) -> list[str]:
    out: list[str] = []
    for rid in ids:
        new = swaps.get(rid, rid)
        if new and new not in out:
            out.append(new)
    return out


def swap_failed(ids: list[str]) -> list[str]:
    """Synchronní, jen z katalogu (pro ukládání mixů)."""
    with Session(engine) as session:
        failed = _failed(session, ids)
        if not failed:
            return ids
        taken = set(ids)
        swaps: dict[str, str | None] = {}
        for rid in failed:
            recording = session.get(Recording, rid)
            twin = _twin(session, recording, taken) if recording else None
            if twin:
                taken.add(twin)
            swaps[rid] = twin
    return _replace(ids, swaps)


# Vygenerované mixy, kde se nesehnatelná skladba vyměňuje i při otevření
# (A6, 14. 10.: stažení selhalo až pár minut po sestavení mixu, náhrada se
# dělala jen při sestavení). Vlastní playlisty uživatele nikdy.
GENERATED_PREFIXES = ("personal:", "home:")


def refresh_failed_items(session: Session, playlist: Any) -> bool:
    """Ve vygenerovaném mixu vymění skladby, jejichž stažení mezitím
    selhalo, za jinou verzi (nebo je vynechá). Vrací, jestli se něco
    změnilo. Bez selhaných je to jeden dotaz."""
    from app.models import PlaylistItem

    if not (playlist.source or "").startswith(GENERATED_PREFIXES):
        return False
    items = session.exec(
        select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id).order_by(PlaylistItem.position)
    ).all()
    ids = [i.recording_id for i in items]
    failed = _failed(session, ids)
    if not failed:
        return False
    taken = set(ids)
    swaps: dict[str, str | None] = {}
    for rid in failed:
        recording = session.get(Recording, rid)
        twin = _twin(session, recording, taken) if recording else None
        if twin:
            taken.add(twin)
        swaps[rid] = twin
    new_ids = _replace(ids, swaps)
    for item in items:
        session.delete(item)
    session.flush()
    for position, rid in enumerate(new_ids):
        session.add(PlaylistItem(playlist_id=playlist.id, recording_id=rid, position=position))
    session.commit()
    logger.info("mix %s: %d nesehnatelných vyměněno/vynecháno při otevření", playlist.id, len(failed))
    return True


async def swap_failed_async(ids: list[str]) -> list[str]:
    """Jako `swap_failed`, a co v katalogu jinou verzi nemá, zkusí najít na
    Deezeru (stejný interpret, stejný název bez závorek)."""
    import asyncio

    from app.catalog.deezer import get_deezer_client
    from app.home import generators as g

    def lookup_targets() -> tuple[set[str], dict[str, str | None], list[tuple[str, str, str]]]:
        with Session(engine) as session:
            failed = _failed(session, ids)
            taken = set(ids)
            swaps: dict[str, str | None] = {}
            todo: list[tuple[str, str, str]] = []
            for rid in failed:
                recording = session.get(Recording, rid)
                twin = _twin(session, recording, taken) if recording else None
                if twin:
                    taken.add(twin)
                    swaps[rid] = twin
                    continue
                swaps[rid] = None
                artist = session.get(Artist, recording.artist_id) if recording and recording.artist_id else None
                if recording and artist and artist.name:
                    todo.append((rid, artist.name, recording.title or ""))
            return failed, swaps, todo

    failed, swaps, todo = await asyncio.to_thread(lookup_targets)
    if not failed:
        return ids
    dz = get_deezer_client()
    for rid, artist, title in todo[:MAX_LOOKUPS]:
        try:
            found: dict[str, Any] = await dz.search(f'artist:"{artist}" track:"{normalize_title(title)}"', 10) or {}
        except Exception:  # noqa: BLE001
            continue
        key = normalize_title(title)
        hits = [
            t
            for t in found.get("data") or []
            if normalize_title(t.get("title") or "") == key
            and normalize_title((t.get("artist") or {}).get("name") or "") == normalize_title(artist)
        ]
        for hit in hits[:3]:
            new_ids = await asyncio.to_thread(g._ingest_tracks, [hit])
            new = new_ids[0] if new_ids else None
            if new and new != rid and new not in ids and not await asyncio.to_thread(_is_failed, new):
                swaps[rid] = new
                break
    logger.info("nesehnatelné: %s nahrazeno, %s vypadlo", sum(1 for v in swaps.values() if v), sum(1 for v in swaps.values() if not v))
    return _replace(ids, swaps)


def _is_failed(rid: str) -> bool:
    with Session(engine) as session:
        return bool(_failed(session, [rid]))
