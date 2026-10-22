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
from app.catalog.artwork import primary_artist_name, same_artist_name
from app.catalog.canonical import album_recordings
from app.catalog.deezer import get_deezer_client
from app.catalog.identity import is_own_artist
from app.db import engine
from app.home import generators as g
from app.home.personal_mixes import _artists_of, _cap_per_artist, _is_junk, _spread
from app.models import Artist, Playlist, PlaylistItem, PlaylistKind, Recording, Release
from app.utils import utcnow

KINDS = ("track", "album", "playlist", "artist")
STATION_SIZE = 50
TTL = timedelta(days=7)
# Rádio i z posluchačova vkusu, ne jen z Deezeru/Last.fm (Kryštof 22. 10.:
# rádio od Danny Very bylo samý nizozemský pop -- oba zdroje berou
# podobnost podle publika, ne zvuku). Jako Spotify/Apple: semínko + známé
# stylem blízko + nové.
KNOWN_SHARE = 1 / 3
KNOWN_TOP_ARTISTS = 200
KNOWN_STYLE_MAX = 0.5
KNOWN_PER_ARTIST = 2


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
            for rec in album_recordings(session, rel):
                if rec.artist_id and rec.artist_id not in artists:
                    artists.append(rec.artist_id)
            return rel.title, artists[:4], []
        if kind == "artist":
            artist = session.get(Artist, target_id)
            if artist is None:
                raise StationError("interpret nenalezen")
            return artist.name, [artist.id], []
        playlist = session.get(Playlist, target_id)
        # Jen čitelné playlisty (vlastní, společné, globální) -- jinak by šlo
        # podle UUID postavit rádio z cizích soukromých Oblíbených.
        from app.models import PlaylistMember
        from app.models import GLOBAL_PLAYLIST_OWNER

        member = (
            playlist is not None
            and session.exec(
                select(PlaylistMember).where(PlaylistMember.playlist_id == playlist.id, PlaylistMember.user_id == user_id)
            ).first()
            is not None
        )
        if playlist is None or (playlist.owner_user_id not in (user_id, GLOBAL_PLAYLIST_OWNER) and not member):
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
        candidates = await get_deezer_client().search_artist(name, trust_name=False)
    except Exception:  # noqa: BLE001
        return None
    for candidate in candidates:
        if same_artist_name(candidate.get("name", ""), name):
            return str(candidate["id"])
    return None


def _seed_recordings(kind: str, target_id: str, rng: random.Random, limit: int = 5) -> list[str]:
    """Pár skladeb, od kterých se rádio odrazí (Last.fm podobné skladby)."""
    with Session(engine) as session:
        if kind == "album":
            ids = [r.id for r in album_recordings(session, target_id)]
        elif kind == "artist":
            ids = [r.id for r in session.exec(select(Recording).where(Recording.artist_id == target_id)).all()]
        else:
            ids = [
                i.recording_id
                for i in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == target_id)).all()
            ]
    rng.shuffle(ids)
    return ids[:limit]


async def _lastfm_similar(recording_id: str, rng: random.Random, limit: int = 25) -> list[dict[str, Any]]:
    from app.catalog import lastfm
    from app.catalog.artwork import _normalize

    with Session(engine) as session:
        rec = session.get(Recording, recording_id)
        artist = session.get(Artist, rec.artist_id) if rec and rec.artist_id else None
        # Vlastní interpret -- Last.fm by vrátil podobné cizí kapele.
        if rec is None or artist is None or is_own_artist(artist):
            return []
        title, name = rec.title, primary_artist_name(artist.name)
    similar = await lastfm.similar_tracks(name, title, limit=limit * 2)
    rng.shuffle(similar)
    dz = get_deezer_client()
    out: list[dict[str, Any]] = []
    for item in similar:
        try:
            found = await dz.find_track(item["artist"], item["title"])
        except Exception:  # noqa: BLE001
            continue
        if not found or not found.get("id") or _is_junk(found):
            continue
        if _normalize((found.get("artist") or {}).get("name", "")) != _normalize(item["artist"]):
            continue
        out.append(found)
        if len(out) >= limit:
            break
    return out


def _guarded(user_id: str, ids: list[str], artist_of: dict[str, str]) -> list[str]:
    """Společný filtr (app/home/guard.py). Slyšené skladby nechává -- rádio
    není jen nová hudba; neslyšené musí projít i pravidly pro nové."""
    from app.home import activation as av
    from app.home import guard

    return guard.load(user_id).filter(ids, artist_of, known=set(av.cached(user_id).total))


async def _familiar_near(
    user_id: str, seed_artists: list[str], rng: random.Random
) -> tuple[list[str], list[str], dict[str, dict[str, float]]]:
    """Posluchačovy známé skladby od interpretů stylem blízko semínka:
    (skladby, ti interpreti, styly). Bere jeho nejposlouchanější interprety,
    od každého pár skladeb podle počtu poslechů."""
    from app.home import activation as av
    from app.home import energy_flow
    from app.home.taste_bridge import artist_styles

    act = await asyncio.to_thread(av.cached, user_id)
    plays: Counter = Counter()
    by_artist: dict[str, list[str]] = {}
    for r, n in act.total.items():
        a = act.artist_of.get(r)
        if a and a not in seed_artists:
            plays[a] += n
            by_artist.setdefault(a, []).append(r)
    top = [a for a, _ in plays.most_common(KNOWN_TOP_ARTISTS)]
    styles = await artist_styles(top + seed_artists)
    centre = energy_flow.style_centre(seed_artists, styles)
    if not centre:
        return [], [], styles
    near = [
        a for a in top
        if (d := energy_flow.style_distance(styles.get(a), centre)) is not None and d <= KNOWN_STYLE_MAX
    ]
    tracks: list[str] = []
    for a in near:
        pool = by_artist[a]
        weights = [act.total[r] for r in pool]
        picked: list[str] = []
        while pool and len(picked) < KNOWN_PER_ARTIST:
            r = rng.choices(pool, weights)[0]
            i = pool.index(r)
            pool, weights = pool[:i] + pool[i + 1:], weights[:i] + weights[i + 1:]
            picked.append(r)
        tracks += picked
    rng.shuffle(tracks)
    return tracks, near, styles


def _cap_known(ids: list[str], heard: set[str], limit: int) -> list[str]:
    """Nejvýš `limit` známých a rovnoměrně mezi novými (ne známé napřed
    a nové v bloku na konci)."""
    known = [r for r in ids if r in heard][:limit]
    new = [r for r in ids if r not in heard]
    total = len(known) + len(new)
    out, ki, ni = [], 0, 0
    for i in range(total):
        if ki < len(known) and (ni >= len(new) or ki * total <= i * len(known)):
            out.append(known[ki])
            ki += 1
        else:
            out.append(new[ni])
            ni += 1
    return out


def _unique_songs(ids: list[str]) -> list[str]:
    """Stejná píseň jen jednou -- i když je interpret v katalogu dvakrát
    ("Kane" a "KANE", Kryštof 22. 10.)."""
    from app.catalog.artwork import _normalize
    from app.home.play_now import _title_key

    seen: set[tuple[str, str]] = set()
    out: list[str] = []
    with Session(engine) as session:
        for r in ids:
            rec = session.get(Recording, r)
            art = session.get(Artist, rec.artist_id) if rec is not None and rec.artist_id else None
            key = (_normalize(primary_artist_name(art.name)) if art else r, _title_key(rec.title) if rec else r)
            if key in seen:
                continue
            seen.add(key)
            out.append(r)
    return out


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
    # samotné "artist radio" by se opakovalo. Napřed posluchačovi interpreti
    # stylem blízko semínka: Deezer "podobní" jsou podle publika (u Danny
    # Very samý nizozemský pop), jeho vlastní okolí stylu ne.
    familiar, near, styles = await _familiar_near(user_id, seed_artists, rng)
    if near and len(seeds) < 4:
        pick = rng.sample(near, min(4 - len(seeds), len(near)))
        seeds += [d for d in await asyncio.gather(*(_deezer_id(a) for a in pick)) if d and d not in seeds]
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
    # Rádio od skladby: navrch podobné skladby z Last.fm (podle toho, co
    # posluchači pouštějí po sobě) -- Deezer "artist radio" je jen podle
    # interpreta a opakuje se.
    lf_ids: list[str] = []
    if kind == "track":
        lf_ids = await asyncio.to_thread(g._ingest_tracks, await _lastfm_similar(first[0], rng))
    ids = lf_ids + [i for i in await asyncio.to_thread(g._ingest_tracks, raw) if i not in lf_ids]
    if kind != "track":
        # Interpret / album / playlist: napřed skladby, které posluchači
        # Last.fm pouštějí spolu s jeho skladbami.
        from app.home import lastfm_taste as lt

        seeds = await asyncio.to_thread(_seed_recordings, kind, target_id, rng)
        lf_ids = await lt.similar_track_ids(seeds, set(seeds), rng, 25, per_seed=15)
        ids = lf_ids + [i for i in ids if i not in lf_ids]
    from app.home import activation as av

    heard = set((await asyncio.to_thread(av.cached, user_id)).total)
    lf_set = set(lf_ids)
    origins = {r: ("known" if r in heard else "new:lastfm" if r in lf_set else "new:deezer") for r in ids}
    origins.update({r: "seed" for r in first})
    ids = [i for i in ids if i not in first]
    artist_of = await asyncio.to_thread(_artists_of, ids + first)
    # Známé stylem blízko semínka a nové jen se stylem blízko semínka a těch
    # známých (OP-ALG1 E; vzdálené styly dřív prošly všechny).
    from app.home import energy_flow
    from app.home.personal_mixes import _interleave
    from app.home.taste_bridge import artist_styles

    familiar = [r for r in familiar if r not in first and r not in ids]
    new = [r for r in ids if r not in heard]
    styles.update(await artist_styles(list({artist_of[r] for r in new if r in artist_of} - styles.keys())))
    off = energy_flow.off_style(new, artist_of, styles, seed_artists + near)
    ids = [r for r in ids if r not in off]
    artist_of.update(await asyncio.to_thread(_artists_of, familiar))
    origins.update({r: "known" for r in familiar})
    want_known = int(STATION_SIZE * KNOWN_SHARE) - sum(1 for r in ids if r in heard)
    ids = _interleave(ids, familiar[: max(0, want_known)]) if want_known > 0 else ids
    ids = await asyncio.to_thread(_guarded, user_id, ids, artist_of)
    ids = await asyncio.to_thread(_unique_songs, ids)
    ids = _spread(_cap_per_artist(ids, artist_of, 3), artist_of)
    # Známých nejvýš třetina -- Deezer rádio jeho vlastních interpretů vrací
    # i to, co zná, a rádio je hlavní místo, kde se nové ujímají.
    ids = _cap_known(ids, heard, int(STATION_SIZE * KNOWN_SHARE))
    # Bez řazení (Kryštof 22. 10.: u rádia pořadí problém nebylo).
    from app.home.obtainable import swap_failed_async

    recording_ids = first + (await swap_failed_async(ids[: STATION_SIZE + 10]))
    recording_ids = recording_ids[:STATION_SIZE]
    if len(recording_ids) < 5:
        raise StationError("na rádio je tu zatím málo podobné hudby")

    covers = await asyncio.to_thread(g._covers_for, recording_ids)
    playlist_id = await asyncio.to_thread(_save, user_id, kind, target_id, name, recording_ids, covers, origins)
    return {"playlistId": playlist_id, "title": f"Rádio · {name}", "count": len(recording_ids)}


def _save(
    user_id: str, kind: str, target_id: str, name: str, recording_ids: list[str], covers: list[str],
    origins: dict[str, str] | None = None,
) -> str:
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
            session.add(PlaylistItem(
                playlist_id=playlist.id, recording_id=recording_id, position=position, origin=(origins or {}).get(recording_id)
            ))
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
