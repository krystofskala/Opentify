""""Poslechnout později" -- seznam hudby na potom (jako YouTube "Watch
later" / Letterboxd watchlist), ne fronta ani playlist.

Položka je skladba, album nebo interpret. Po poslechnutí se sama přesune do
"Poslechnuto" (`listened_at`):
  - skladba: jakmile se započítá poslech (≥ polovina skladby, viz listens.py),
  - album: poslechnuto aspoň `ALBUM_SHARE` jeho skladeb od přidání,
  - interpret: aspoň `ARTIST_TRACKS` různých jeho skladeb od přidání.
"""

from __future__ import annotations

import math
from datetime import date, timedelta
from typing import Any

from sqlmodel import Session, func, select

from app.db import engine
from app.models import Artist, Listen, ListenLater, Recording, Release
from app.utils import utcnow

KINDS = ("track", "album", "artist")
ALBUM_SHARE = 0.6
ARTIST_TRACKS = 5
REMIND_AFTER = timedelta(days=14)
LISTENED_SHOWN = 50


def _payload(session: Session, item: ListenLater) -> dict[str, Any] | None:
    from app.home.service import AlbumCardOut, _recording_out

    out: dict[str, Any] = {
        "id": item.id,
        "kind": item.kind,
        "note": item.note,
        "source": item.source,
        "addedAt": item.added_at.isoformat(),
        "listenedAt": item.listened_at.isoformat() if item.listened_at else None,
    }
    if item.kind == "track":
        rec = session.get(Recording, item.target_id)
        if rec is None:
            return None
        out["track"] = _recording_out(session, rec).model_dump(mode="json", by_alias=True)
    elif item.kind == "album":
        rel = session.get(Release, item.target_id)
        if rel is None:
            return None
        artist = session.get(Artist, rel.artist_id)
        out["album"] = AlbumCardOut(
            id=rel.id,
            title=rel.title,
            artist_id=rel.artist_id,
            artist_name=artist.name if artist else None,
            release_date=rel.release_date,
            release_type=rel.release_type,
            images=rel.images or [],
        ).model_dump(mode="json", by_alias=True)
    else:
        artist = session.get(Artist, item.target_id)
        if artist is None:
            return None
        out["artist"] = {"id": artist.id, "name": artist.name, "images": artist.images or []}
    return out


def list_items(user_id: str) -> dict[str, Any]:
    with Session(engine) as session:
        active = session.exec(
            select(ListenLater)
            .where(ListenLater.user_id == user_id, ListenLater.listened_at.is_(None))  # type: ignore[union-attr]
            .order_by(ListenLater.added_at.desc())  # type: ignore[attr-defined]
        ).all()
        listened = session.exec(
            select(ListenLater)
            .where(ListenLater.user_id == user_id, ListenLater.listened_at.is_not(None))  # type: ignore[union-attr]
            .order_by(ListenLater.listened_at.desc())  # type: ignore[union-attr]
            .limit(LISTENED_SHOWN)
        ).all()
        active_out = [p for p in (_payload(session, i) for i in active) if p]
        # Připomínka na Domů: něco, co tu leží přes 2 týdny -- každý den jiné.
        now = utcnow().replace(tzinfo=None)  # SQLite vrací časy bez zóny
        old = [
            p
            for i, p in zip(active, (_payload(session, i) for i in active))
            if p and now - i.added_at.replace(tzinfo=None) >= REMIND_AFTER
        ]
        reminder = old[date.today().toordinal() % len(old)] if old else None
        return {
            "active": active_out,
            "listened": [p for p in (_payload(session, i) for i in listened) if p],
            "reminder": reminder,
        }


def add(
    user_id: str, kind: str, target_id: str, note: str | None, source: str | None = None
) -> dict[str, Any] | None:
    """Přidá (nebo z "Poslechnuto" vrátí zpět) -- stejná věc je v seznamu jednou."""
    with Session(engine) as session:
        model = {"track": Recording, "album": Release, "artist": Artist}[kind]
        if session.get(model, target_id) is None:
            return None
        item = session.exec(
            select(ListenLater).where(
                ListenLater.user_id == user_id, ListenLater.kind == kind, ListenLater.target_id == target_id
            )
        ).first()
        if item is None:
            item = ListenLater(user_id=user_id, kind=kind, target_id=target_id)
        if item.listened_at is not None:
            item.listened_at = None
            item.added_at = utcnow()
        if note is not None:
            item.note = note.strip() or None
        if source is not None:
            item.source = source
        session.add(item)
        session.commit()
        session.refresh(item)
        return _payload(session, item)


def update(user_id: str, item_id: str, *, note: str | None = None, restore: bool = False) -> bool:
    with Session(engine) as session:
        item = session.get(ListenLater, item_id)
        if item is None or item.user_id != user_id:
            return False
        if note is not None:
            item.note = note.strip() or None
        if restore:
            item.listened_at = None
            item.added_at = utcnow()
        session.add(item)
        session.commit()
        return True


def remove(user_id: str, item_id: str) -> bool:
    with Session(engine) as session:
        item = session.get(ListenLater, item_id)
        if item is None or item.user_id != user_id:
            return False
        session.delete(item)
        session.commit()
        return True


MIX_PER_ITEM = 2


def mix_candidates(user_id: str) -> list[tuple[str, str]]:
    """(recording, artist) ze seznamu pro automatické mixy -- skladba sama,
    z alba/interpreta pár skladeb (stažené napřed, nevyslechnuté od přidání)."""
    from app.models import MediaAsset, MediaAssetStatus

    out: list[tuple[str, str]] = []
    with Session(engine) as session:
        items = session.exec(
            select(ListenLater).where(ListenLater.user_id == user_id, ListenLater.listened_at.is_(None))  # type: ignore[union-attr]
        ).all()
        for item in items:
            if item.kind == "track":
                rec = session.get(Recording, item.target_id)
                if rec is not None and rec.artist_id:
                    out.append((rec.id, rec.artist_id))
                continue
            column = Recording.release_id if item.kind == "album" else Recording.artist_id
            recs = session.exec(select(Recording).where(column == item.target_id).limit(60)).all()
            heard = set(
                session.exec(
                    select(Listen.recording_id).where(
                        Listen.user_id == user_id,
                        Listen.played_at >= item.added_at,
                        Listen.recording_id.in_([r.id for r in recs]),  # type: ignore[attr-defined]
                    )
                ).all()
            )

            def available(r: Recording) -> bool:
                asset = session.get(MediaAsset, r.id)
                return asset is not None and asset.status == MediaAssetStatus.AVAILABLE

            fresh = sorted((r for r in recs if r.id not in heard and r.artist_id), key=lambda r: (not available(r), r.track_number or 99))
            out.extend((r.id, r.artist_id) for r in fresh[:MIX_PER_ITEM])  # type: ignore[misc]
    return out


def weave(tracks: list[str], extra: list[str], limit: int = 3) -> list[str]:
    """Vloží až `limit` skladeb ze seznamu rozprostřeně (3., 10., 17. místo)."""
    out = [t for t in tracks]
    for n, rid in enumerate([r for r in extra if r not in tracks][:limit]):
        out.insert(min(len(out), 2 + n * 7), rid)
    return out


def _distinct_listened(session: Session, user_id: str, since, where) -> int:  # noqa: ANN001
    return session.exec(
        select(func.count(func.distinct(Listen.recording_id)))
        .join(Recording, Recording.id == Listen.recording_id)
        .where(Listen.user_id == user_id, Listen.played_at >= since, where)
    ).one()


def on_listen(user_id: str, recording_id: str) -> None:
    """Volá se po každém započítaném poslechu (listens.record_listen)."""
    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
        if rec is None:
            return
        targets = [("track", rec.id)]
        if rec.release_id:
            targets.append(("album", rec.release_id))
        if rec.artist_id:
            targets.append(("artist", rec.artist_id))
        items = session.exec(
            select(ListenLater).where(
                ListenLater.user_id == user_id,
                ListenLater.listened_at.is_(None),  # type: ignore[union-attr]
                ListenLater.target_id.in_([t for _, t in targets]),  # type: ignore[attr-defined]
            )
        ).all()
        changed = False
        for item in items:
            done = False
            if item.kind == "track":
                done = item.target_id == rec.id
            elif item.kind == "album":
                total = session.exec(
                    select(func.count()).select_from(Recording).where(Recording.release_id == item.target_id)
                ).one()
                heard = _distinct_listened(session, user_id, item.added_at, Recording.release_id == item.target_id)
                done = total > 0 and heard >= max(1, math.ceil(total * ALBUM_SHARE))
            elif item.kind == "artist":
                heard = _distinct_listened(session, user_id, item.added_at, Recording.artist_id == item.target_id)
                done = heard >= ARTIST_TRACKS
            if done:
                item.listened_at = utcnow()
                session.add(item)
                changed = True
        if changed:
            session.commit()
