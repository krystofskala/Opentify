"""Česká hudba na Domů -- celá sekce i po žánrech (připínají se jako žánry).

Stojí na štítcích posluchačů Last.fm ("czech", "czech rock", "czech folk",
...), stejně jako stránky stylů (app/tags.py): vitrína = "Tvůj mix · X"
(tvoje skladby od interpretů s tím štítkem + objevy od podobných),
"X · nejoblíbenější", alba a interpreti. Sestavuje se na pozadí jen pro
profily, které sekci mají zapnutou / žánr připnutý; Domů čte uložený snímek.
"""

from __future__ import annotations

import asyncio
import logging
from typing import Any

from sqlmodel import Session

from app.db import engine
from app.models import HomeSnapshot
from app.utils import utcnow

logger = logging.getLogger("vault.home.czech")

# id -> (štítek Last.fm, název, barva vinylu)
CZECH_GENRES: dict[str, tuple[str, str, str]] = {
    "cz": ("czech", "Česká hudba", "#D7141A"),
    "cz-rock": ("czech rock", "Český rock", "#C0392B"),
    "cz-folk": ("czech folk", "Český folk", "#B9770E"),
    "cz-pop": ("czech pop", "Český pop", "#E84393"),
    "cz-hiphop": ("czech hip-hop", "Český hip-hop", "#6C5CE7"),
    "cz-punk": ("czech punk", "Český punk", "#2D3436"),
    "cz-metal": ("czech metal", "Český metal", "#636E72"),
    "cz-indie": ("czech indie", "Český indie", "#00B894"),
    "cz-alternative": ("czech alternative", "Česká alternativa", "#0984E3"),
    "cz-underground": ("czech underground", "Český underground", "#6D4C41"),
    "cz-jazz": ("czech jazz", "Český jazz", "#8E44AD"),
    "cz-electronic": ("czech electronic", "Česká elektronika", "#00CEC9"),
    "cz-country": ("czech country", "Český country", "#D35400"),
    "cz-bluegrass": ("czech bluegrass", "Český bluegrass", "#27AE60"),
}
TAG_TITLES = {tag: title for tag, title, _c in CZECH_GENRES.values()}


# Ručně vybraní interpreti, kde štítek Last.fm skoro nic nemá (živě: táta
# si připnul Český bluegrass a sekce zůstala prázdná -- 2 interpreti, žádný
# mix). Jen jednoznačná jména (přesná shoda na Deezeru).
SEED_ARTISTS: dict[str, tuple[str, ...]] = {
    "cz-bluegrass": (
        "Druhá tráva", "Poutníci", "Robert Křesťan", "Malina Brothers", "Taxmeni",
        "G-Runs 'n' Roses", "Banjo Band Ivana Mládka",
    ),
}


def _own_artists_for(tag: str) -> list[str]:
    """Vlastní interpreti s tímhle stylem (Kontrast = czech bluegrass)."""
    from sqlmodel import select

    from app.catalog.identity import is_own_artist
    from app.models import Artist

    with Session(engine) as session:
        return [
            a.id
            for a in session.exec(select(Artist)).all()
            if is_own_artist(a) and tag in [str(s).lower() for s in (a.external_refs or {}).get("styles") or []]
        ]


async def _seed_mix(genre_id: str, user_id: str) -> tuple[str | None, list[str]]:
    """Mix z vybraných interpretů -> (id playlistu, id interpretů)."""
    from app import browse
    from app.home import generators as g
    from app.models import PlaylistKind, Recording

    ids = await browse.seed_tracks(genre_id, SEED_ARTISTS[genre_id])
    if not ids:
        return None, []
    with Session(engine) as session:
        artists: list[str] = []
        for rid in ids:
            rec = session.get(Recording, rid)
            if rec and rec.artist_id and rec.artist_id not in artists:
                artists.append(rec.artist_id)
    title = CZECH_GENRES[genre_id][1]
    playlist_id = g._save_playlist(
        owner=user_id,
        source=f"czech-seed:{genre_id}",
        title=title,
        description=f"{title} – výběr z české scény, každý den jinak",
        kind=PlaylistKind.PERSONAL_MIX,
        section="czech",
        recording_ids=ids[:40],
        cover_urls=g._covers_for(ids[:4]),
        ttl=g.DAILY_TTL,
    )
    return playlist_id, artists


def section_id(genre_id: str) -> str:
    return "czech" if genre_id == "cz" else f"czech_{genre_id[3:]}"


def pinned(user_id: str) -> list[str]:
    """České žánry připnuté profilem (uloženo spolu s žánry, `cz-*`)."""
    from app.models import AppUser

    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        ids = (user.home_genres if user else None) or []
    return [i for i in ids if i in CZECH_GENRES and i != "cz"]


def key(genre_id: str, user_id: str) -> str:
    return f"czech:{genre_id}:{user_id}"


async def build_one(genre_id: str, user_id: str) -> int:
    from app import tags

    tag = CZECH_GENRES[genre_id][0]
    page = await tags.tag_page(tag, None)
    mix = await tags.tag_mix(tag)
    for_you = await tags.tag_for_you(tag, user_id)
    mix_id = mix.get("playlistId")
    artist_ids = [a["id"] for a in page.get("topArtists") or []]
    if genre_id in SEED_ARTISTS:
        seed_mix, seed_artists = await _seed_mix(genre_id, user_id)
        mix_id = mix_id or seed_mix
        artist_ids = [*artist_ids, *(a for a in seed_artists if a not in artist_ids)]
    own = await asyncio.to_thread(_own_artists_for, tag)
    artist_ids = [*own, *(a for a in artist_ids if a not in own)]
    payload = {
        "forYouId": for_you,
        "mixId": mix_id,
        "artistIds": artist_ids[:10],
        "albumIds": [a["id"] for a in page.get("albums") or []][:10],
    }
    with Session(engine) as session:
        row = session.get(HomeSnapshot, key(genre_id, user_id)) or HomeSnapshot(key=key(genre_id, user_id))
        row.payload = payload
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    return len(payload["artistIds"])


async def build_enabled() -> int:
    """Běh na pozadí: "Česká hudba" (je-li zapnutá) + připnuté české žánry."""
    from app.home import generators as g
    from app.home.service import section_enabled

    user_id = g.home_user()
    wanted = (["cz"] if section_enabled(user_id, "czech") else []) + pinned(user_id)
    for genre_id in wanted:
        try:
            await build_one(genre_id, user_id)
        except Exception:  # noqa: BLE001 - jeden žánr nesmí shodit ostatní
            logger.exception("česká hudba %s pro %s selhala", genre_id, user_id[:8])
    return len(wanted)


def render(session: Session, user_id: str, genre_id: str) -> dict[str, Any] | None:
    """Vitrína (typ genre_showcase): mixy napřed, pak alba a interpreti na
    přeskáčku. "Zobrazit vše" otevře stránku stylu."""
    from app import browse
    from app.home.service import _card
    from app.models import Artist, Playlist, Release

    row = session.get(HomeSnapshot, key(genre_id, user_id))
    data = (row.payload or {}) if row else {}
    items: list[dict[str, Any]] = []
    for pid in (data.get("forYouId"), data.get("mixId")):
        pl = session.get(Playlist, pid) if pid else None
        if pl is not None:
            card = _card(session, pl)
            if card.item_count > 0:
                items.append({"itemType": "playlist", **card.model_dump(mode="json", by_alias=True)})
    albums = [r for r in (session.get(Release, i) for i in data.get("albumIds") or []) if r is not None]
    artists = [a for a in (session.get(Artist, i) for i in data.get("artistIds") or []) if a is not None]
    for i in range(max(len(albums), len(artists))):
        if i < len(albums):
            items.append({"itemType": "album", "badge": None, **browse._album_card(session, albums[i])})
        if i < len(artists):
            items.append({"itemType": "artist", **browse._artist_card(artists[i])})
    if len(items) < 3:
        return None
    tag, title, _color = CZECH_GENRES[genre_id]
    return {"id": section_id(genre_id), "title": title, "type": "genre_showcase", "tag": tag, "items": items}
