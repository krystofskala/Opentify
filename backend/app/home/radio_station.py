"""Rádio podle skladby, alba, playlistu nebo interpreta (jako Spotify "Přejít
na rádio").

Semínko -> interpreti (u playlistu nejčastější) -> Deezer "artist radio"
(skladby interpreta + podobných) semínkových interpretů a pár jim
podobných -> ingest přes stávající Deezer cestu (AntiAIFilter, deduplikace)
-> max. pár skladeb na interpreta, střídání interpretů, u skladby ona sama
první. Při každém spuštění nové pořadí/výběr.

Uloží se jako playlist (`kind=RADIO`, `source="radio:{kind}:{id}"`) bez
sekce -- na Domů se nemíchá, otevře se přímo; po týdnu vyprší.
"""

from __future__ import annotations

import asyncio
import random
from collections import Counter
from datetime import timedelta
from typing import Any

from sqlmodel import Session, select

from app.library.dislikes import without_disliked
from app.catalog.artwork import _names_match, primary_artist_name
from app.catalog.deezer import get_deezer_client
from app.db import engine
from app.home import generators as g
from app.home.personal_mixes import _artists_of, _cap_per_artist, _is_junk, _spread
from app.models import Artist, Playlist, PlaylistItem, PlaylistKind, Recording, Release
from app.utils import utcnow

KINDS = ("track", "album", "playlist", "artist")
STATION_SIZE = 50
TTL = timedelta(days=7)


class StationError(Exception):
    pass


def _seed(user_id: str, kind: str, target_id: str) -> tuple[str, list[str], list[str]]:
    """(název, naše id semínkových interpretů, skladby, které mají jít první)."""
    with Session(engine) as session:
        if kind == "track":
            rec = session.get(Recording, target_id)
            if rec is None or not rec.artist_id:
                raise StationError("skladba nenalezena")
            return rec.title, [rec.artist_id], [rec.id]
        if kind == "album":
            rel = session.get(Release, target_id)
            if rel is None:
                raise StationError("album nenalezeno")
            artists = [rel.artist_id] if rel.artist_id else []
            for rec in session.exec(select(Recording).where(Recording.release_id == rel.id)).all():
                if rec.artist_id and rec.artist_id not in artists:
                    artists.append(rec.artist_id)
            return rel.title, artists[:4], []
        if kind == "artist":
            artist = session.get(Artist, target_id)
            if artist is None:
                raise StationError("interpret nenalezen")
            return artist.name, [artist.id], []
        playlist = session.get(Playlist, target_id)
        if playlist is None:
            raise StationError("playlist nenalezen")
        counts: Counter = Counter()
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all():
            rec = session.get(Recording, item.recording_id)
            if rec is not None and rec.artist_id:
                counts[rec.artist_id] += 1
        # Oblíbené mají v DB anglický název z importu ("Liked Songs").
        title = "Oblíbené skladby" if playlist.source == "liked-songs" else playlist.title
        return title, [a for a, _ in counts.most_common(6)], []


async def _deezer_id(artist_id: str) -> str | None:
    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None:
            return None
        if artist.deezer_id:
            return artist.deezer_id
        name = primary_artist_name(artist.name)
    try:
        candidates = await get_deezer_client().search_artist(name)
    except Exception:  # noqa: BLE001
        return None
    for candidate in candidates:
        if _names_match(candidate.get("name", ""), name):
            return str(candidate["id"])
    return None


async def build_station(user_id: str, kind: str, target_id: str) -> dict[str, Any]:
    if kind not in KINDS:
        raise StationError("neznámý druh")
    name, seed_artists, first = await asyncio.to_thread(_seed, user_id, kind, target_id)
    dz = get_deezer_client()
    rng = random.Random()

    seeds = [d for d in await asyncio.gather(*(_deezer_id(a) for a in seed_artists)) if d]
    if not seeds:
        raise StationError("k tomu teď rádio nenajdu (interpret není na Deezeru)")
    # U jednoho interpreta (skladba/interpret) přibrat pár podobných --
    # samotné "artist radio" by se opakovalo.
    if len(seeds) < 3:
        try:
            related = await dz.artist_related(seeds[0], 12) or []
        except Exception:  # noqa: BLE001
            related = []
        rng.shuffle(related)
        seeds += [str(r["id"]) for r in related[: 3 - len(seeds) + 1] if r.get("id")]

    raw: list[dict[str, Any]] = []
    for seed in seeds[:6]:
        try:
            raw.extend(await dz.artist_radio(seed) or [])
        except Exception:  # noqa: BLE001
            continue
    raw = [t for t in raw if not _is_junk(t)]
    rng.shuffle(raw)
    ids = await asyncio.to_thread(g._ingest_tracks, raw)
    ids = [i for i in ids if i not in first]
    artist_of = await asyncio.to_thread(_artists_of, ids + first)
    ids = _spread(_cap_per_artist(ids, artist_of, 3), artist_of)
    recording_ids = (first + ids)[:STATION_SIZE]
    if len(recording_ids) < 5:
        raise StationError("na rádio je tu zatím málo podobné hudby")

    covers = await asyncio.to_thread(g._covers_for, recording_ids)
    playlist_id = await asyncio.to_thread(_save, user_id, kind, target_id, name, recording_ids, covers)
    return {"playlistId": playlist_id, "title": f"Rádio · {name}", "count": len(recording_ids)}


def _save(user_id: str, kind: str, target_id: str, name: str, recording_ids: list[str], covers: list[str]) -> str:
    source = f"radio:{kind}:{target_id}"
    with Session(engine) as session:
        playlist = session.exec(
            select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == source)
        ).first()
        if playlist is None:
            playlist = Playlist(owner_user_id=user_id, title=name, kind=PlaylistKind.RADIO, source=source)
            session.add(playlist)
            session.flush()
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all():
            session.delete(item)
        for position, recording_id in enumerate(without_disliked(user_id, recording_ids)):
            session.add(PlaylistItem(playlist_id=playlist.id, recording_id=recording_id, position=position))
        now = utcnow()
        what = {"track": "skladby", "album": "alba", "playlist": "playlistu", "artist": "interpreta"}[kind]
        playlist.title = f"Rádio · {name}"
        playlist.description = f"Podobná hudba podle {what} „{name}“. Při každém spuštění rádia jiný výběr."
        playlist.kind = PlaylistKind.RADIO
        playlist.section = None
        playlist.cover_urls = covers[:4]
        playlist.generated_at = now
        playlist.expires_at = now + TTL
        playlist.updated_at = now
        session.add(playlist)
        session.commit()
        return playlist.id
