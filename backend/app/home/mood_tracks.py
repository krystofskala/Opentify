"""Nálada SKLADBY, ne interpreta (mixy nálad, 8. 10.).

Dřív patřil do nálady celý interpret, když on nebo tři jemu podobní byli
v redakčních playlistech Deezeru -- do Párty se tak dostali Angus & Julia
Stone s čímkoli. Teď se rozhoduje u každé skladby ze tří zdrojů:

1. štítky skladby z Last.fm (sad, chill, workout…), plní je na pozadí
   `warm()` -- skládání mixu čte jen to, co už je v cache,
2. vlastní rozbor zvuku (`TrackFeatures`: energie, tempo) -- u Cvičení
   a Spánku sám dokladem, u ostatních jen veto (balada do Cvičení ne),
3. skladba přímo v redakčním playlistu nálady na Deezeru.
"""

from __future__ import annotations

import asyncio
import logging
from dataclasses import dataclass

from sqlmodel import Session, select

from app.catalog import lastfm
from app.catalog.identity import is_own_artist
from app.db import engine
from app.models import Artist, Recording, TrackFeatures

logger = logging.getLogger(__name__)

# Štítky Last.fm (u skladeb) pro každou náladu z Procházet.
MOOD_TAGS: dict[str, tuple[str, ...]] = {
    "sleep": ("sleep", "relaxing", "calm", "lullaby", "soothing", "peaceful"),
    "focus": ("study", "focus", "concentration", "studying", "work music"),
    "chill": ("chill", "chillout", "mellow", "relaxing", "laid back", "chilled"),
    "workout": ("workout", "gym", "running", "energetic", "pump up", "motivation"),
    "party": ("party", "dance", "club", "party music", "danceable"),
    "feelgood": ("feel good", "happy", "upbeat", "uplifting", "feelgood", "good mood"),
    "romance": ("love songs", "love", "romantic", "love song"),
    "sad": ("sad", "melancholy", "melancholic", "depressing", "heartbreak", "sad songs"),
    "morning": ("morning", "coffee", "sunday morning", "wake up", "breakfast"),
    "roadtrip": ("road trip", "driving", "roadtrip", "travel", "drive"),
}
# Štítek skladby se počítá od váhy 20 (Last.fm dává 0-100 vůči nejsilnějšímu).
MIN_TAG = 20
# Jména, která nejsou interpreti (redakční playlisty Deezeru je občas mají).
JUNK_ARTISTS = {"deezer", "various artists", "various", "unknown artist", "[unknown]"}


@dataclass
class TrackInfo:
    title: str
    artist: str
    deezer_id: str | None
    own: bool
    energy: float | None
    bpm: float | None


def audio_veto(mood: str, energy: float | None, bpm: float | None) -> bool:
    """Zvuk náladě jasně odporuje (energie 0-1: medián knihovny ~0,45)."""
    if energy is None:
        return False
    return {
        "workout": energy < 0.35,
        "party": energy < 0.3,
        "sleep": energy > 0.45,
        "focus": energy > 0.7,
        "chill": energy > 0.7,
        "sad": energy > 0.8,
        "roadtrip": energy < 0.15,
    }.get(mood, False)


def audio_evidence(mood: str, energy: float | None, bpm: float | None) -> bool:
    """Zvuk sám stačí jako doklad -- jen kde je to jednoznačné."""
    if energy is None:
        return False
    if mood == "workout":
        return energy >= 0.7 and (bpm is None or bpm >= 110)
    if mood == "sleep":
        return energy <= 0.15
    return False


def tag_strength(tags: list[tuple[str, int]] | None, mood: str) -> int:
    wanted = MOOD_TAGS.get(mood, ())
    return max((c for t, c in tags or [] if t.strip().lower() in wanted), default=0)


def _infos(rids: list[str]) -> dict[str, TrackInfo]:
    with Session(engine) as session:
        rows = session.exec(
            select(Recording.id, Recording.title, Recording.deezer_id, Artist.name, Artist.id)
            .join(Artist, Artist.id == Recording.artist_id)
            .where(Recording.id.in_(rids))  # type: ignore[attr-defined]
        ).all()
        feats = {
            f.recording_id: f
            for f in session.exec(select(TrackFeatures).where(TrackFeatures.recording_id.in_(rids))).all()  # type: ignore[attr-defined]
        }
    out: dict[str, TrackInfo] = {}
    for rid, title, dz, name, artist_id in rows:
        f = feats.get(rid)
        bpm = f.bpm if f is not None and (f.bpm_confidence or 0) >= 0.3 else None
        out[rid] = TrackInfo(title or "", name or "", dz, is_own_artist(artist_id), f.energy if f else None, bpm)
    return out


async def evidence(rids: list[str], mood: str, deezer_track_ids: set[str]) -> dict[str, float]:
    """recording -> skóre nálady: ≥ 1 = doložená skladba (štítek / playlist
    nálady / jednoznačný zvuk), 0 = nic nevíme, < 0 = zvuk odporuje."""
    infos = await asyncio.to_thread(_infos, list(dict.fromkeys(rids)))
    sem = asyncio.Semaphore(20)

    async def tags_of(info: TrackInfo) -> list[tuple[str, int]] | None:
        # Vlastní interpret: Last.fm by našel stejnojmennou cizí skladbu.
        if info.own or not info.title or not info.artist:
            return None
        async with sem:
            return await lastfm.track_top_tags(info.artist, info.title, cached_only=True)

    ids = list(infos)
    tag_lists = await asyncio.gather(*(tags_of(infos[r]) for r in ids))
    out: dict[str, float] = {}
    for rid, tags in zip(ids, tag_lists):
        info = infos[rid]
        if audio_veto(mood, info.energy, info.bpm):
            out[rid] = -1.0
            continue
        score = 0.0
        if tag_strength(tags, mood) >= MIN_TAG:
            score += 1.0
        if info.deezer_id and info.deezer_id in deezer_track_ids:
            score += 1.0
        if audio_evidence(mood, info.energy, info.bpm):
            score += 1.0
        out[rid] = score
    return out


def _warm_candidates(limit: int) -> list[tuple[str, str, str]]:
    """(recording, interpret, název) nejposlouchanějších a oblíbených skladeb
    všech profilů -- pro ty se štítky vyplatí znát."""
    from collections import Counter
    from datetime import timedelta

    from app.models import Listen, Playlist, PlaylistItem
    from app.utils import utcnow

    since = (utcnow() - timedelta(days=365)).replace(tzinfo=None)
    with Session(engine) as session:
        counts = Counter(
            session.exec(select(Listen.recording_id).where(Listen.played_at >= since)).all()
        )
        liked = session.exec(
            select(PlaylistItem.recording_id)
            .join(Playlist, Playlist.id == PlaylistItem.playlist_id)
            .where(Playlist.source == "liked-songs")
        ).all()
        for rid in liked:
            counts[rid] += 3
        top = [rid for rid, _c in counts.most_common(limit)]
        rows = session.exec(
            select(Recording.id, Recording.title, Artist.name, Artist.id)
            .join(Artist, Artist.id == Recording.artist_id)
            .where(Recording.id.in_(top))  # type: ignore[attr-defined]
        ).all()
    order = {rid: i for i, rid in enumerate(top)}
    return [
        (rid, name, title)
        for rid, title, name, artist_id in sorted(rows, key=lambda r: order.get(r[0], 0))
        if title and name and not is_own_artist(artist_id) and name.strip().lower() not in JUNK_ARTISTS
    ]


async def warm(budget: int = 150, limit: int = 4000) -> int:
    """Doplní do cache štítky skladeb, které ještě nejsou (nejhranější napřed);
    nejvýš `budget` dotazů na Last.fm za běh. Vrací počet dotazů."""
    candidates = await asyncio.to_thread(_warm_candidates, limit)
    fetched = 0
    for _rid, artist, title in candidates:
        if fetched >= budget:
            break
        if await lastfm.track_top_tags(artist, title, cached_only=True) is not None:
            continue
        await lastfm.track_top_tags(artist, title)
        fetched += 1
    if fetched:
        logger.info("nálady: štítky skladeb doplněny (%d)", fetched)
    return fetched
