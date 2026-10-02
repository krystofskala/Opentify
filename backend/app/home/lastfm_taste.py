"""Last.fm v osobních mixech: podobnost interpretů a skladeb podle toho, co
posluchači opravdu poslouchají spolu (Deezer "related" a rádio táhnou
k populárnímu a u menších žánrů -- bluegrass, česká scéna -- jsou slabé),
a štítky interpretů jako žánry/styly. Bez klíče vše vrací prázdné a mixy
jedou po staru jen z Deezeru.
"""

from __future__ import annotations

import asyncio
import random
from collections import Counter
from typing import Any

from sqlmodel import Session

from app.catalog import lastfm
from app.catalog.artwork import _normalize, primary_artist_name
from app.db import engine
from app.models import Artist, Recording


def norm(name: str) -> str:
    return _normalize(primary_artist_name(name or ""))


async def similar_artist_names(name: str, limit: int = 30, min_match: float = 0.08) -> list[tuple[str, float]]:
    """[(jméno, shoda 0-1)] podobných interpretů podle posluchačů."""
    if not name:
        return []
    items = await lastfm.similar_artists(primary_artist_name(name), limit=limit)
    return [(i["name"], i["match"]) for i in items if i.get("match", 0) >= min_match]


async def artist_tags(name: str) -> list[str]:
    """Styly interpreta (štítky Last.fm), nejsilnější první."""
    from app.tags import is_style

    info = await lastfm.artist_info(primary_artist_name(name)) if name else None
    return [t.lower() for t in (info or {}).get("tags") or [] if is_style(t)]


def _track_info(recording_ids: list[str]) -> list[tuple[str, str]]:
    out = []
    with Session(engine) as session:
        for rid in recording_ids:
            rec = session.get(Recording, rid)
            artist = session.get(Artist, rec.artist_id) if rec and rec.artist_id else None
            if rec is not None and artist is not None and rec.title:
                out.append((primary_artist_name(artist.name), rec.title))
    return out


async def similar_track_ids(
    seed_recording_ids: list[str], exclude: set[str], rng: random.Random, want: int, per_seed: int = 25
) -> list[str]:
    """Skladby, které posluchači pouštějí spolu se semínky -- seřazené podle
    toho, k kolika semínkům a jak silně sedí; převzaté přes Deezer (jen
    přesná shoda interpreta), bez `exclude`."""
    from app.tags import _resolve_tracks

    seeds = await asyncio.to_thread(_track_info, seed_recording_ids)
    if not seeds or want <= 0:
        return []
    score: Counter = Counter()
    meta: dict[tuple[str, str], dict[str, str]] = {}
    for artist, title in seeds:
        for item in await lastfm.similar_tracks(artist, title, limit=per_seed):
            key = (norm(item["artist"]), _normalize(item["title"]))
            score[key] += item.get("match", 0) + 0.2  # víc semínek = výš
            meta.setdefault(key, {"artist": item["artist"], "title": item["title"]})
    if not score:
        return []
    ranked = [meta[k] for k, _ in score.most_common(want * 3)]
    # Nejsilnější napřed, zbytek promíchat (ať se mix den ode dne liší).
    head, tail = ranked[: want // 2], ranked[want // 2 :]
    rng.shuffle(tail)
    ids = await _resolve_tracks(head + tail, want * 2)
    out: list[str] = []
    per_artist: Counter = Counter()
    with Session(engine) as session:
        for rid in ids:
            if rid in exclude or rid in out:
                continue
            rec = session.get(Recording, rid)
            artist_id = rec.artist_id if rec else None
            if per_artist[artist_id] >= 2:
                continue
            per_artist[artist_id] += 1
            out.append(rid)
            if len(out) >= want:
                break
    return out


def merge_shares(*sources: dict[str, float]) -> dict[str, float]:
    out: dict[str, float] = {}
    for src in sources:
        for k, v in (src or {}).items():
            out[k] = max(out.get(k, 0.0), v)
    return out


async def tag_category_shares(name: str) -> dict[str, float]:
    """Štítky interpreta -> naše žánry ({kategorie: síla 0-1}). První štítek
    nejsilnější. Podžánry se počítají k hlavnímu žánru (newgrass -> bluegrass)."""
    from app.browse import LASTFM_TAGS
    from app.tags import SUBGENRES

    tags = (await artist_tags(name))[:6]
    out: dict[str, float] = {}
    for i, tag in enumerate(tags):
        weight = max(0.3, 1.0 - i * 0.15)
        for cat in {c for c, words in LASTFM_TAGS.items() if tag in words} | {c for c, subs in SUBGENRES.items() if tag in subs}:
            out[cat] = max(out.get(cat, 0.0), weight)
    return out


async def user_styles(top_artists: list[tuple[str, float]], limit: int = 12) -> list[str]:
    """Nejposlouchanější styly profilu: štítky jeho interpretů vážené tím,
    jak moc je poslouchá."""
    score: Counter = Counter()
    for name, weight in top_artists:
        for i, tag in enumerate((await artist_tags(name))[:5]):
            score[tag] += weight * max(0.2, 1.0 - i * 0.2)
    return [t for t, _ in score.most_common(limit)]


def any_name(names: list[Any]) -> list[str]:  # pragma: no cover -- drobnost pro typy
    return [str(n) for n in names]
