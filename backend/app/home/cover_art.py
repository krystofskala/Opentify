"""Fakta pro generované obaly mixů (14. 10., obaly verze 2: "každý tvar je
fakt"). Klient z nich kreslí: Objevy kruhy podle počtu skladeb a zvlnění
podle tempa, denní mix vlny podle podílů stylů, Top roku sloupce podle
poslechů po měsících; fotky interpretů do kruhu / horní části.

Počítá se při sestavení karty a drží v paměti, dokud se playlist znovu
nevygeneruje (`generated_at`).
"""

from __future__ import annotations

from collections import Counter
from typing import Any

from sqlmodel import Session, func, select

from app.catalog.artwork import _is_deezer_placeholder
from app.models import Artist, Listen, Playlist, PlaylistItem, Recording, TrackFeatures

_cache: dict[tuple[str, str], dict[str, Any] | None] = {}
_PHOTOS = 3


def _items(session: Session, playlist_id: str) -> list[tuple[str, str | None]]:
    return list(
        session.exec(
            select(PlaylistItem.recording_id, Recording.artist_id)
            .join(Recording, Recording.id == PlaylistItem.recording_id)
            .where(PlaylistItem.playlist_id == playlist_id)
            .order_by(PlaylistItem.position)
        ).all()
    )


def _photos(session: Session, artist_ids: list[str]) -> list[str]:
    """Fotky interpretů v pořadí podle počtu skladeb; vlastní interpreti
    (bez fotky z katalogu) a zástupné obrázky Deezeru se přeskočí."""
    out: list[str] = []
    for artist_id in artist_ids:
        artist = session.get(Artist, artist_id)
        image = (artist.images or [None])[0] if artist else None
        if image and not _is_deezer_placeholder(image) and image not in out:
            out.append(image)
        if len(out) >= _PHOTOS:
            break
    return out


def _shares(session: Session, artist_counts: Counter) -> list[float]:
    """Podíly tří nejčastějších stylů (Deezer žánry interpretů vážené počtem
    skladeb), součet 1."""
    styles: Counter = Counter()
    for artist_id, n in artist_counts.items():
        artist = session.get(Artist, artist_id)
        shares = (((artist.external_refs or {}) if artist else {}).get("dzGenres") or {}).get("shares") or {}
        for style, share in shares.items():
            styles[style] += float(share) * n
    top = [v for _s, v in styles.most_common(3)]
    total = sum(top)
    return [round(v / total, 3) for v in top] if total else []


def _months(session: Session, user_id: str, year: str) -> list[int]:
    rows = session.exec(
        select(func.strftime("%m", Listen.played_at), func.count())
        .where(Listen.user_id == user_id, func.strftime("%Y", Listen.played_at) == year)
        .group_by(func.strftime("%m", Listen.played_at))
    ).all()
    by_month = {int(m): int(c) for m, c in rows}
    return [by_month.get(i, 0) for i in range(1, 13)]


def _years(session: Session, user_id: str, first: int, last: int) -> list[int]:
    rows = session.exec(
        select(func.strftime("%Y", Listen.played_at), func.count())
        .where(Listen.user_id == user_id)
        .group_by(func.strftime("%Y", Listen.played_at))
    ).all()
    by_year = {int(y): int(c) for y, c in rows if y and y.isdigit()}
    return [by_year.get(y, 0) for y in range(first, last + 1)]


def facts(session: Session, playlist: Playlist) -> dict[str, Any] | None:
    source = playlist.source or ""
    if not source.startswith("personal:"):
        return None
    key = (playlist.id, str(playlist.generated_at))
    if key in _cache:
        return _cache[key]
    out: dict[str, Any] | None = None
    if source.startswith("personal:year:"):
        out = {"months": _months(session, playlist.owner_user_id, source.rsplit(":", 1)[-1])}
    elif source.startswith("personal:decade:"):
        # personal:decade:2016-2026:top -> poslechy po letech (sloupce obalu).
        years = [int(y) for y in source.split(":")[2].split("-")[:2] if y.isdigit()]
        if len(years) == 2:
            out = {"years": _years(session, playlist.owner_user_id, years[0], years[1]), "from": years[0]}
    else:
        items = _items(session, playlist.id)
        counts = Counter(a for _r, a in items if a)
        out = {"tracks": len(items), "artists": len(counts), "photos": _photos(session, [a for a, _n in counts.most_common(12)])}
        if source.startswith("personal:discover-weekly"):
            bpms = [
                b
                for b in session.exec(
                    select(TrackFeatures.bpm).where(TrackFeatures.recording_id.in_([r for r, _a in items]))
                ).all()
                if b
            ]
            out["bpm"] = round(sum(bpms) / len(bpms)) if bpms else None
            if playlist.generated_at:
                out["week"] = playlist.generated_at.isocalendar()[1]
        elif source.startswith("personal:daily-mix:"):
            out["shares"] = _shares(session, counts)
            desc = playlist.description or ""
            style, _, rest = desc.partition(" · ")
            out["style"] = style if rest else None
            out["artistsLine"] = (rest or desc).split(" · ")[0] or None
    if len(_cache) > 2000:
        _cache.clear()
    _cache[key] = out
    return out
