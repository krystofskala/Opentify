"""Hledání žánrů a stylů (Hledat › Vše, tlačítka nahoře).

"blues" najde kategorii Blues (Procházet) i styly Chicago Blues, Delta Blues,
Blues Rock...; "harmonica" najde štítek posluchačů, i když to žánr není.

Zdroje:
- kategorie Procházet (`browse.CATEGORIES`) -> stránka kategorie,
- oficiální seznam žánrů MusicBrainz (~2000, jednou za měsíc) -> stránka stylu,
- české žánry (`home.czech`),
- přímo hledaný výraz jako štítek Last.fm, když ho posluchači opravdu
  používají (instrumenty, nálady, scény...).
"""

from __future__ import annotations

import logging
from typing import Any

from app.catalog.cache import cached_json
from app.download_match import fold, tokens

logger = logging.getLogger("vault.genre_search")

MONTH = 30 * 24 * 3600
LASTFM_MIN_REACH = 300


async def mb_genres() -> list[str]:
    from app.catalog.musicbrainz import MusicBrainzError, get_musicbrainz_client

    async def fetch() -> list[str]:
        mb = get_musicbrainz_client()
        names: list[str] = []
        offset = 0
        while True:
            try:
                data = await mb._get("/genre/all", {"limit": 100, "offset": offset})
            except MusicBrainzError:
                break
            batch = [g.get("name") for g in data.get("genres") or [] if g.get("name")]
            names += batch
            offset += len(batch)
            if not batch or offset >= int(data.get("genre-count") or 0):
                break
        return names

    try:
        return await cached_json("mb:genres:all", MONTH, fetch, is_empty=lambda v: not v) or []
    except Exception:  # noqa: BLE001 - bez seznamu jen kategorie a Last.fm
        logger.exception("seznam žánrů MusicBrainz nedostupný")
        return []


async def popularity() -> dict[str, int]:
    """Pořadí štítků podle Last.fm (nejpoužívanější první), jednou za měsíc."""
    from app.catalog import lastfm

    out: dict[str, int] = {}
    for page in (1, 2, 3, 4, 5):
        data = await lastfm.get({"method": "chart.gettoptags", "limit": "200", "page": str(page)}, ttl=MONTH)
        for t in ((data or {}).get("tags") or {}).get("tag") or []:
            name = fold(t.get("name") or "")
            if name and name not in out:
                out[name] = len(out)
    return out


def _matches(query_words: list[str], name: str) -> int | None:
    """Pořadí shody (menší = lepší), None = nesedí. Každé hledané slovo musí
    být začátkem některého slova názvu ("blu" -> "Delta Blues")."""
    words = tokens(name)
    if not query_words or not all(any(w.startswith(q) for w in words) for q in query_words):
        return None
    joined = " ".join(words)
    q = " ".join(query_words)
    if joined == q:
        return 0
    if joined.startswith(q):
        return 1
    return 2


async def _my_styles(user_id: str | None) -> set[str]:
    from app.home import generators as g
    from app.home.personal_mixes import styles_key
    from sqlmodel import Session

    from app.db import engine
    from app.models import HomeSnapshot

    try:
        with Session(engine) as session:
            snap = session.get(HomeSnapshot, styles_key(user_id or g.home_user()))
        return {fold(t) for t in ((snap.payload or {}).get("tags") or [])} if snap else set()
    except Exception:  # noqa: BLE001
        return set()


async def search(query: str, limit: int = 14, user_id: str | None = None) -> list[dict[str, Any]]:
    from app import browse
    from app.catalog import lastfm
    from app.home.czech import CZECH_GENRES
    from app.tags import title_of

    q_words = tokens(query)
    if not q_words:
        return []
    out: list[tuple[tuple, dict[str, Any]]] = []
    seen: set[str] = set()
    pop = await popularity()
    mine = await _my_styles(user_id)

    def add(rank: int, item: dict[str, Any], key: str) -> None:
        k = fold(key)
        if k in seen:
            return
        seen.add(k)
        # Přesná shoda první; pak kategorie, tvoje styly, oblíbenost na
        # Last.fm (Punk Rock před Rock Kapak), kratší název.
        exact = 0 if rank == 0 else 1
        kind = 0 if item["kind"] == "category" else 1
        out.append(((exact, kind, 0 if k in mine else 1, pop.get(k, 10_000), len(key)), item))

    for c in browse.CATEGORIES:
        rank = min((r for r in (_matches(q_words, c.title), _matches(q_words, c.id)) if r is not None), default=None)
        if rank is not None:
            add(rank, {"kind": "category", "id": c.id, "title": c.title, "color": c.color}, c.title)
    for tag, title, _color in CZECH_GENRES.values():
        rank = min((r for r in (_matches(q_words, title), _matches(q_words, tag)) if r is not None), default=None)
        if rank is not None:
            add(rank, {"kind": "tag", "tag": tag, "title": title}, tag)
    for name in await mb_genres():
        rank = _matches(q_words, name)
        if rank is not None:
            add(rank, {"kind": "tag", "tag": name, "title": title_of(name)}, name)
    # Výraz sám jako štítek posluchačů (harmonica, acoustic...).
    if fold(query.strip()) not in seen:
        info = await lastfm.get({"method": "tag.getinfo", "tag": query.strip()}, ttl=MONTH)
        tag = (info or {}).get("tag") or {}
        if int(tag.get("reach") or 0) >= LASTFM_MIN_REACH:
            add(0, {"kind": "tag", "tag": tag.get("name") or query.strip(), "title": title_of(tag.get("name") or query.strip())}, query.strip())
    out.sort(key=lambda r: r[0])
    return [item for _key, item in out[:limit]]
