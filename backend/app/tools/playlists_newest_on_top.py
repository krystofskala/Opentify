"""Jednorázově přeskládá stávající vlastní playlisty podle data přidání,
nejnovější nahoře (Kryštof 24. 10.): nové skladby od teď jdou nahoru
(routes/playlists.add_item), dřívější přidání ležela na konci.

Jen playlisty založené v appce (bez `source`). Importy (Spotify, Apple,
YouTube) mají jako datum přidání čas importu, takže by se jen obrátily
(žebříček „nejoblíbenější skladby roku“ odzadu); Oblíbené jsou nejnovější
nahoře už teď. Stejné datum = dosavadní pořadí.

    python -m app.tools.playlists_newest_on_top [--apply]

Záloha původních pozic: /data/db/playlist-positions-<čas>.json
"""

from __future__ import annotations

import json
import sys
from datetime import datetime

from sqlmodel import Session, select

from app.db import engine
from app.models import Playlist, PlaylistItem, PlaylistKind


def newest_first(items: list[PlaylistItem]) -> list[PlaylistItem]:
    """Podle data přidání sestupně; bez data a ve stejné minutě dosavadní
    pořadí -- kopie playlistu nebo hromadné přidání zapíše celé pořadí během
    pár milisekund a to by se jinak jen obrátilo."""
    by_position = sorted(items, key=lambda i: i.position)
    rank = {i.id: n for n, i in enumerate(by_position)}
    return sorted(by_position, key=lambda i: (-(int(i.added_at.timestamp()) // 60 if i.added_at else 0), rank[i.id]))


def main(apply: bool) -> None:
    backup: dict[str, list[list]] = {}
    changed = 0
    with Session(engine) as session:
        playlists = session.exec(
            select(Playlist).where(Playlist.kind == PlaylistKind.USER, Playlist.source == None)  # noqa: E711
        ).all()
        for playlist in playlists:
            items = list(session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all())
            current = [i.id for i in sorted(items, key=lambda i: i.position)]
            target = newest_first(items)
            if [i.id for i in target] == current:
                continue
            changed += 1
            backup[playlist.id] = [[i.id, i.position] for i in items]
            print(f"{playlist.owner_user_id[:12]:12} {playlist.title[:40]:40} {len(items):5} položek")
            if apply:
                for position, item in enumerate(target):
                    item.position = position
                    session.add(item)
        if apply and changed:
            path = f"/data/db/playlist-positions-{datetime.now():%Y%m%d-%H%M%S}.json"
            with open(path, "w", encoding="utf-8") as f:
                json.dump(backup, f)
            session.commit()
            print(f"záloha: {path}")
    print(f"{'přeskládáno' if apply else 'přeskládalo by se'}: {changed} playlistů")


if __name__ == "__main__":
    main("--apply" in sys.argv[1:])
