"""Interpreti stejného jména (14. 10.: stránka neznámého "Journey" z roku
2024 s 23 fanoušky na Deezeru ukazovala životopis, štítky a 3,4 mil.
posluchačů skutečné kapely -- ty se dohledávají podle jména).

Malý jmenovec = bez MusicBrainz id a stejnojmenný interpret na Deezeru má
mnohem víc fanoušků. U něj se nic podle jména nedohledává (Last.fm,
hledání na Wikidatech), stránka nabídne přepnout na ostatní jmenovce.
"""

from __future__ import annotations

from typing import Any

from sqlmodel import Session, select

from app.catalog.artwork import primary_artist_name
from app.catalog.deezer import get_deezer_client
from app.models import Artist

# Jiný stejnojmenný musí mít aspoň tolik fanoušků a tolikrát víc.
MIN_FANS = 10_000
RATIO = 20


def _same(a: str, b: str) -> bool:
    return primary_artist_name(a).casefold().strip() == primary_artist_name(b).casefold().strip()


async def deezer_candidates(name: str) -> list[dict[str, Any]]:
    """Stejnojmenní interpreti na Deezeru (s počtem fanoušků)."""
    try:
        found = await get_deezer_client().search_artist(primary_artist_name(name), 10)
    except Exception:  # noqa: BLE001
        return []
    return [a for a in found if _same(str(a.get("name") or ""), name)]


async def is_minor_namesake(artist: Artist) -> bool:
    if artist.mbid or not artist.deezer_id:
        return False
    candidates = await deezer_candidates(artist.name)
    own = next((int(a.get("nb_fan") or 0) for a in candidates if str(a.get("id")) == str(artist.deezer_id)), 0)
    best_other = max((int(a.get("nb_fan") or 0) for a in candidates if str(a.get("id")) != str(artist.deezer_id)), default=0)
    return best_other >= MIN_FANS and best_other >= RATIO * max(own, 1)


async def namesakes(session: Session, artist: Artist) -> list[dict[str, Any]]:
    """Ostatní interpreti stejného jména: z katalogu i z Deezeru (ti se
    přidají do katalogu, ať se na ně dá přejít). Nejznámější napřed."""
    from app.catalog.deezer_ingest import deezer_image, ingest_artist

    out: dict[str, dict[str, Any]] = {}
    fans: dict[str, int] = {}
    for candidate in await deezer_candidates(artist.name):
        if str(candidate.get("id")) == str(artist.deezer_id):
            continue  # to je on sám
        # Napřed přesně podle Deezer id -- `ingest_artist` páruje i podle
        # jména a jmenovce by sloučil se slavným (živě: oba Journey -> kapela).
        row = session.exec(select(Artist).where(Artist.deezer_id == str(candidate.get("id")))).first() or ingest_artist(
            session, candidate
        )
        if row is None or row.id == artist.id or row.id in out:
            continue
        fans[row.id] = int(candidate.get("nb_fan") or 0)
        out[row.id] = {
            "id": row.id,
            "name": row.name,
            "imageUrl": (row.images or [None])[0] or deezer_image(candidate.get("picture_xl") or candidate.get("picture_big")),
            "fans": fans[row.id],
            "albums": candidate.get("nb_album"),
        }
    for row in session.exec(select(Artist).where(Artist.name == artist.name, Artist.id != artist.id)).all():
        out.setdefault(
            row.id, {"id": row.id, "name": row.name, "imageUrl": (row.images or [None])[0], "fans": None, "albums": None}
        )
    session.commit()
    return sorted(out.values(), key=lambda a: -(a["fans"] or 0))
