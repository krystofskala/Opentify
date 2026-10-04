"""Doplní délku skladby, kterou katalog nezná (`Recording.duration_ms` je
NULL), z délky staženého souboru změřené při vlnovce
(`MediaAsset.waveform_duration_ms`). Jen u dostupných souborů a NIKDY nepřepíše
existující délku z katalogu (pravidlo: žádné délky zkrácené o ticho).

    python -m app.tools.fill_durations_from_waveform [--dry-run]"""
from __future__ import annotations

import sys

from sqlmodel import Session, select

from app.db import engine
from app.models import MediaAsset, MediaAssetStatus, Recording


def fill(session: Session) -> list[tuple[Recording, int]]:
    rows = session.exec(
        select(Recording, MediaAsset.waveform_duration_ms)
        .join(MediaAsset, MediaAsset.recording_id == Recording.id)
        .where(
            MediaAsset.status == MediaAssetStatus.AVAILABLE,
            Recording.duration_ms.is_(None),  # type: ignore[union-attr]
            MediaAsset.waveform_duration_ms.is_not(None),  # type: ignore[union-attr]
            MediaAsset.waveform_duration_ms > 0,  # type: ignore[operator]
        )
    ).all()
    changed = []
    for rec, ms in rows:
        if rec.duration_ms is None:  # pojistka -- katalogovou délku nikdy nepřepsat
            rec.duration_ms = int(ms)
            session.add(rec)
            changed.append((rec, int(ms)))
    return changed


def main(dry: bool) -> None:
    with Session(engine) as session:
        changed = fill(session)
        print(f"skladeb bez délky, doplnitelných ze souboru: {len(changed)}")
        for rec, ms in changed[:30]:
            print(f"  {rec.id} {rec.title!r}: {ms // 60000}:{ms // 1000 % 60:02d}")
        if dry:
            session.rollback()
            print("(nanečisto)")
            return
        session.commit()
        print("uloženo")


if __name__ == "__main__":
    main("--dry-run" in sys.argv)
