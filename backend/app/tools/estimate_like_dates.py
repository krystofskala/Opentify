"""Odhad, kdy byla skladba přidána do Oblíbených (13. 10.): import z
YourLibrary.json data nemá a všechna srdíčka dostala den importu (u Kryštofa
504 skladeb 27. 9.). Pořadí ale odpovídá Spotify (nejnovější nahoře) a
k tomu je historie poslechů:

  odhad = nejdřív první poslech skladby, nejpozději odhad novější skladby
  (pořadí se nesmí obrátit), nikdy pozdější než den importu.

Upravují se jen položky z "hromadného" dne (víc než 15 srdíček za den) --
srdíčka dané v appce mají skutečný čas. Přesné datum dá import Exportify CSV
("Added At"), ten má přednost (spustí se znovu jen nad hromadnými dny).

    python -m app.tools.estimate_like_dates <profil> [--apply]

Záloha původních hodnot: /data/db/like-dates-<profil>.json
"""

from __future__ import annotations

import json
import sys
from collections import Counter
from datetime import datetime

from sqlmodel import Session, func, select

from app.db import engine
from app.library.spotify_import import LIKED_SONGS_SOURCE
from app.models import Listen, Playlist, PlaylistItem

BULK_PER_DAY = 15


def estimate(user_id: str) -> list[tuple[PlaylistItem, object]]:
    """[(položka, odhad)] jen pro položky z hromadných dnů."""
    with Session(engine) as session:
        pid = session.exec(
            select(Playlist.id).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
        ).first()
        if not pid:
            return []
        items = session.exec(
            select(PlaylistItem).where(PlaylistItem.playlist_id == pid).order_by(PlaylistItem.position.desc())  # type: ignore[attr-defined]
        ).all()  # nejstarší první
        per_day = Counter(i.added_at.date() for i in items if i.added_at)
        bulk = [i for i in items if i.added_at and per_day[i.added_at.date()] > BULK_PER_DAY]
        if not bulk:
            return []
        firsts = dict(
            session.exec(
                select(Listen.recording_id, func.min(Listen.played_at))
                .where(Listen.user_id == user_id, Listen.recording_id.in_([i.recording_id for i in bulk]))  # type: ignore[union-attr]
                .group_by(Listen.recording_id)
            ).all()
        )
        session.expunge_all()
    # Monotónní proložení (pořadí Spotify) přes mediány: jedna skladba
    # s pozdním prvním poslechem (jiná verze, poslech pod jiným id) neposune
    # všechny novější -- dřív prostý "nejpozději jako předchozí" ano.
    known = [(i, firsts[i.recording_id].timestamp()) for i in bulk if firsts.get(i.recording_id)]
    fitted = _isotonic_median([t for _i, t in known])
    est_of = {i.id: t for (i, _t), t in zip(known, fitted)}
    out = []
    last = None
    for item in bulk:
        t = est_of.get(item.id, last)  # bez poslechu: jako starší soused
        if t is None:
            continue
        last = t
        est = min(datetime.fromtimestamp(t), item.added_at)
        out.append((item, est))
    return out


def _isotonic_median(values: list[float]) -> list[float]:
    """Neklesající posloupnost nejblíž `values` (L1, bloky s mediánem)."""
    blocks: list[list[float]] = []
    for v in values:
        blocks.append([v])
        while len(blocks) > 1 and _median(blocks[-2]) > _median(blocks[-1]):
            last = blocks.pop()
            blocks[-1].extend(last)
    out: list[float] = []
    for b in blocks:
        m = _median(b)
        out.extend([m] * len(b))
    return out


def _median(xs: list[float]) -> float:
    s = sorted(xs)
    return s[len(s) // 2]


def main() -> None:
    user_id = sys.argv[1]
    apply = "--apply" in sys.argv
    pairs = estimate(user_id)
    years = Counter(est.year for _i, est in pairs)
    print(f"{user_id}: {len(pairs)} srdíček k odhadu; podle roku: {dict(sorted(years.items()))}")
    for item, est in pairs[:: max(1, len(pairs) // 8)]:
        print(f"  pozice {item.position:5}  {item.added_at:%Y-%m-%d} -> {est:%Y-%m-%d}")
    if not apply or not pairs:
        return
    backup = f"/data/db/like-dates-{user_id}.json"
    with open(backup, "w") as f:
        json.dump({i.id: i.added_at.isoformat() for i, _e in pairs}, f)
    with Session(engine) as session:
        for item, est in pairs:
            row = session.get(PlaylistItem, item.id)
            if row is not None:
                row.added_at = est
                session.add(row)
        session.commit()
    print(f"zapsáno, záloha {backup}")


if __name__ == "__main__":
    main()
