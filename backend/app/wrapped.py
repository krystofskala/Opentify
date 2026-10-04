"""Wrapped -- roční (a desetiletý) souhrn poslechu jako Spotify Wrapped,
jen dostupný napořád.

Období: každý rok od 2016 s aspoň `MIN_PLAYS` přehráními a "dekáda"
2016–2026. Rozběhnutý rok a dekáda jsou do `UNLOCK_AT` zamčené (překvapení
na Nový rok 2027) -- vrací se jen upoutávka s odpočtem, žádná čísla, a
playlisty dekády vzniknou až po odemčení.

Minuty = skutečná délka přehrání (`Listen.duration_played_ms`), u poslechů
bez ní délka skladby. Žánry podle zařazení interpretů z vlastních mixů
(Deezer žánry alb, viz app/home/category_mixes.py); nejposlouchanější
nezařazené interprety období se zařadí při výpočtu.
"""

from __future__ import annotations

import asyncio
import os
from collections import Counter, defaultdict
from datetime import datetime, timedelta, timezone
from typing import Any

from sqlmodel import Session, select

from app.browse import CATEGORIES
from app.catalog.cache import cached_json
from app.db import engine
from app.home import category_mixes as cm
from app.home import generators as g
from app.home import personal_mixes as pm
from app.models import Artist, Listen, Playlist, PlaylistKind, Recording, Release

FIRST_YEAR = 2016
DECADE = "decade"
DECADE_LAST_YEAR = 2026
MIN_PLAYS = 200
DEFAULT_TRACK_MS = 3 * 60 * 1000
CLASSIFY_BUDGET = 40
EVERGREEN_MIN_YEARS = 3

# Půlnoc 1. 1. 2027 v Praze (UTC+1).
UNLOCK_AT = datetime(2026, 12, 31, 23, 0, tzinfo=timezone.utc)

_GENRE_TITLES = {c.id: c.title for c in CATEGORIES if c.group == "genre"}
_GENRE_COLORS = {c.id: c.color for c in CATEGORIES if c.group == "genre"}


def _now() -> datetime:
    return datetime.now(timezone.utc)


def _unlocked() -> bool:
    # WRAPPED_PREVIEW=1 jen pro vývoj (zkouška výpočtu bez odemčení).
    return _now() >= UNLOCK_AT or os.environ.get("WRAPPED_PREVIEW") == "1"


def _local(dt: datetime) -> datetime:
    return pm._aware(dt).astimezone(pm._TZ)


# --------------------------------------------------------------------------
# Data
# --------------------------------------------------------------------------


def _load(user_id: str) -> tuple[list[tuple[str, datetime, int]], dict[str, datetime], dict[str, str | None]]:
    """Poslechy od FIRST_YEAR (recording, místní čas, ms) + první poslech
    každého interpreta vůbec (i před 2016 -- kvůli "objevům")."""
    rows: list[tuple[str, datetime, int]] = []
    first_artist: dict[str, datetime] = {}
    with Session(engine) as session:
        durations = {}
        artist_of: dict[str, str | None] = {}
        for rid, played, ms in session.exec(
            select(Listen.recording_id, Listen.played_at, Listen.duration_played_ms).where(Listen.user_id == user_id)
        ).all():
            if rid not in artist_of:
                rec = session.get(Recording, rid)
                artist_of[rid] = rec.artist_id if rec else None
                durations[rid] = rec.duration_ms if rec else None
            local = _local(played)
            artist = artist_of[rid]
            if artist and (artist not in first_artist or local < first_artist[artist]):
                first_artist[artist] = local
            if local.year < FIRST_YEAR:
                continue
            rows.append((rid, local, ms or durations[rid] or DEFAULT_TRACK_MS))
    return rows, first_artist, artist_of


def available_periods(user_id: str) -> dict[str, Any]:
    with Session(engine) as session:
        counts = Counter(
            _local(p).year
            for p in session.exec(select(Listen.played_at).where(Listen.user_id == user_id)).all()
        )
    unlocked = _unlocked()
    current = _local(_now()).year
    years = []
    for year in sorted((y for y in counts if y >= FIRST_YEAR and counts[y] >= MIN_PLAYS), reverse=True):
        # Rozběhnutý rok: do odemčení zamčený (a po něm "zatím", dokud neskončí).
        locked = year >= DECADE_LAST_YEAR and not unlocked
        years.append({"id": str(year), "year": year, "locked": locked, "partial": year == current})
    return {
        "unlockAt": UNLOCK_AT.isoformat(),
        "decade": {"id": DECADE, "from": FIRST_YEAR, "to": DECADE_LAST_YEAR, "locked": not unlocked},
        "years": years,
    }


def _artist_info(session: Session, artist_id: str) -> dict[str, Any]:
    artist = session.get(Artist, artist_id)
    return {
        "id": artist_id,
        "name": artist.name if artist else "?",
        "imageUrl": (artist.images or [None])[0] if artist else None,
    }


def _track_info(session: Session, recording_id: str) -> dict[str, Any]:
    rec = session.get(Recording, recording_id)
    release = session.get(Release, rec.release_id) if rec and rec.release_id else None
    artist = session.get(Artist, rec.artist_id) if rec and rec.artist_id else None
    return {
        "id": recording_id,
        "title": rec.title if rec else "?",
        "artistId": rec.artist_id if rec else None,
        "artistName": artist.name if artist else None,
        "releaseId": rec.release_id if rec else None,
        "imageUrl": (release.images or [None])[0] if release else None,
    }


async def _genre_shares(artist_ids: list[str]) -> dict[str, dict[str, float]]:
    """artist -> {žánr: podíl, součet 1}; nezařazené z prvních
    `CLASSIFY_BUDGET` se zařadí přes Deezer."""
    stored = await asyncio.to_thread(cm._stored_shares, artist_ids)
    missing = [a for a in artist_ids[:CLASSIFY_BUDGET] if stored.get(a) is None]
    if missing:
        taste = pm.Taste()
        with Session(engine) as session:
            for a in missing:
                artist = session.get(Artist, a)
                if artist is not None:
                    taste.artist_name[a] = artist.name
                    if artist.deezer_id:
                        taste.artist_deezer[a] = artist.deezer_id
        for a in missing:
            if a in taste.artist_name:
                stored[a] = await cm._classify(taste, a)
                await asyncio.sleep(0.05)
    out = {}
    for a, shares in stored.items():
        genres = {k: v for k, v in (shares or {}).items() if k in _GENRE_TITLES}
        total = sum(genres.values())
        if total:
            out[a] = {k: v / total for k, v in genres.items()}
    return out


async def _stats(user_id: str, period: str) -> dict[str, Any]:
    rows, first_artist, artist_of = await asyncio.to_thread(_load, user_id)
    if period == DECADE:
        years = set(range(FIRST_YEAR, DECADE_LAST_YEAR + 1))
    else:
        years = {int(period)}
    rows = [r for r in rows if r[1].year in years]
    if not rows:
        return {"id": period, "empty": True}

    track_plays: Counter = Counter()
    track_ms: Counter = Counter()
    artist_plays: Counter = Counter()
    artist_ms: Counter = Counter()
    month_ms: Counter = Counter()
    hour_plays: Counter = Counter()
    year_track: dict[int, Counter] = defaultdict(Counter)
    year_artist_ms: dict[int, Counter] = defaultdict(Counter)
    days: set[str] = set()
    total_ms = 0
    for rid, at, ms in rows:
        a = artist_of.get(rid)
        track_plays[rid] += 1
        track_ms[rid] += ms
        if a:
            artist_plays[a] += 1
            artist_ms[a] += ms
            year_artist_ms[at.year][a] += ms
        month_ms[at.month if period != DECADE else at.year] += ms
        hour_plays[at.hour] += 1
        year_track[at.year][rid] += 1
        days.add(at.date().isoformat())
        total_ms += ms

    top_artists = [a for a, _ in artist_ms.most_common(50)]
    shares = await _genre_shares(top_artists)
    genre_ms: Counter = Counter()
    for a in top_artists:
        for genre, share in (shares.get(a) or {}).items():
            genre_ms[genre] += artist_ms[a] * share
    classified = sum(genre_ms.values()) or 1

    new_artists = [a for a in artist_ms if a in first_artist and first_artist[a].year in years]
    top_new = max(new_artists, key=lambda a: artist_ms[a], default=None)

    ranked_tracks = sorted(track_plays, key=lambda r: (-track_plays[r], -track_ms[r]))
    # Nejhranější skladba každého interpreta -- hraje pod jeho obrazovkou.
    artist_top_track: dict[str, str] = {}
    for rid in ranked_tracks:
        a = artist_of.get(rid)
        if a and a not in artist_top_track:
            artist_top_track[a] = rid

    def minutes(ms: float) -> int:
        return int(round(ms / 60000))

    def assemble() -> dict[str, Any]:
        with Session(engine) as session:
            out: dict[str, Any] = {
                "id": period,
                "label": f"{FIRST_YEAR}–{DECADE_LAST_YEAR}" if period == DECADE else period,
                "partial": period != DECADE and int(period) == _local(_now()).year,
                "totalMinutes": minutes(total_ms),
                "plays": len(rows),
                "daysListened": len(days),
                "artistsCount": len(artist_ms),
                "tracksCount": len(track_plays),
                "topArtists": [
                    _artist_info(session, a)
                    | {"minutes": minutes(artist_ms[a]), "plays": artist_plays[a], "trackId": artist_top_track.get(a)}
                    for a in top_artists[:5]
                ],
                "topTracks": [
                    _track_info(session, r) | {"plays": track_plays[r], "minutes": minutes(track_ms[r])}
                    for r in ranked_tracks[:5]
                ],
                "topGenres": [
                    {
                        "id": genre,
                        "title": _GENRE_TITLES[genre],
                        "color": _GENRE_COLORS[genre],
                        "minutes": minutes(ms),
                        "percent": round(ms / classified * 100),
                    }
                    for genre, ms in genre_ms.most_common(5)
                ],
                "newArtists": len(new_artists),
                "topNewArtist": (
                    _artist_info(session, top_new)
                    | {"minutes": minutes(artist_ms[top_new]), "trackId": artist_top_track.get(top_new)}
                    if top_new
                    else None
                ),
                "peakHour": hour_plays.most_common(1)[0][0],
                "hours": [hour_plays.get(h, 0) for h in range(24)],
                # Rok: minuty po měsících; dekáda: po letech.
                "timeline": [
                    {"key": k, "minutes": minutes(month_ms.get(k, 0))}
                    for k in (sorted(years) if period == DECADE else range(1, 13))
                ],
            }
            if period == DECADE:
                out["eras"] = [
                    {
                        "year": y,
                        "artist": _artist_info(session, year_artist_ms[y].most_common(1)[0][0]),
                        "track": _track_info(session, year_track[y].most_common(1)[0][0]),
                    }
                    for y in sorted(years)
                    if year_artist_ms[y]
                ]
                tops = {y: {r for r, _ in year_track[y].most_common(100)} for y in year_track}
                stays = Counter(r for top in tops.values() for r in top)
                evergreens = sorted(
                    (r for r, n in stays.items() if n >= EVERGREEN_MIN_YEARS), key=lambda r: (-stays[r], -track_plays[r])
                )
                out["evergreens"] = [_track_info(session, r) | {"years": stays[r]} for r in evergreens[:5]]
                out["playlists"] = _decade_playlists(ranked_tracks, evergreens, year_track)
            else:
                playlist = session.exec(
                    select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == f"personal:year:{period}")
                ).first()
                out["playlists"] = [{"id": playlist.id, "title": playlist.title}] if playlist else []
            return out

    return await asyncio.to_thread(assemble)


def _decade_playlists(ranked: list[str], evergreens: list[str], year_track: dict[int, Counter]) -> list[dict[str, str]]:
    label = f"{FIRST_YEAR}–{DECADE_LAST_YEAR}"
    journey: list[str] = []
    for y in sorted(year_track):
        for r, _ in year_track[y].most_common(5):
            if r not in journey:
                journey.append(r)
    specs = [
        ("top", f"Top 100 dekády {label}", "Nejposlouchanější skladby celé dekády", ranked[:100]),
        ("evergreens", "Nesmrtelné", f"Skladby, které se ti vracely rok co rok ({label})", evergreens[:100]),
        ("journey", "Cesta dekádou", f"Top 5 každého roku, chronologicky {label}", journey),
    ]
    out = []
    for key, title, description, ids in specs:
        if not ids:
            continue
        playlist_id = g._save_playlist(
            owner=g.home_user(),
            # Roky ve zdroji -- klient z nich skládá popisek obalu ("16–26").
            source=f"personal:decade:{FIRST_YEAR}-{DECADE_LAST_YEAR}:{key}",
            title=title,
            description=description,
            kind=PlaylistKind.PERSONAL_MIX,
            section="years",
            recording_ids=ids,
            cover_urls=g._covers_for(ids),
            ttl=timedelta(days=3650),
        )
        out.append({"id": playlist_id, "title": title})
    return out


async def period_stats(user_id: str, period: str) -> dict[str, Any] | None:
    """`None` = neexistující období. Zamčené vrací jen `{"locked": True}`."""
    if period != DECADE and not (period.isdigit() and FIRST_YEAR <= int(period) <= 2100):
        return None
    locked = (period == DECADE or int(period) >= DECADE_LAST_YEAR) and not _unlocked()
    if locked:
        return {"id": period, "locked": True, "unlockAt": UNLOCK_AT.isoformat()}
    current = _local(_now()).year
    finished = period != DECADE and int(period) < current
    # Uzavřený rok se nemění (týden cache); rozběhnutý rok a dekáda po dnech.
    key = f"wrapped:v4:{user_id}:{period}" + ("" if finished else f":{pm._day_key()}")
    return await cached_json(key, 7 * 24 * 3600 if finished else 24 * 3600, lambda: _stats(user_id, period))


SNIPPET_START_SHARE = 0.33  # třetina skladby -- obvykle už refrén, ne intro
SNIPPET_MIN_START_MS = 20_000


async def snippet(recording_id: str) -> dict[str, Any] | None:
    """Úryvek skladby pod obrazovku Wrappedu: stažená skladba z knihovny
    (od třetiny), jinak 30s ukázka z Deezeru (veřejné CDN, nic se
    nestahuje). `None` = není co pustit."""
    from app.catalog.artwork import _normalize, primary_artist_name
    from app.catalog.deezer import get_deezer_client
    from app.models import MediaAsset, MediaAssetStatus

    def local() -> tuple[dict[str, Any] | None, tuple[str | None, str, str]]:
        with Session(engine) as session:
            rec = session.get(Recording, recording_id)
            if rec is None:
                return None, (None, "", "")
            asset = session.get(MediaAsset, recording_id)
            artist = session.get(Artist, rec.artist_id) if rec.artist_id else None
            dz = rec.deezer_id or (rec.external_refs or {}).get("shareDeezerId")
            if asset is not None and asset.status == MediaAssetStatus.AVAILABLE:
                length = rec.duration_ms or asset.waveform_duration_ms or 0
                start = max(SNIPPET_MIN_START_MS, int(length * SNIPPET_START_SHARE)) if length > 60_000 else 0
                return {"url": f"/api/v1/tracks/{recording_id}/stream", "startMs": start}, (dz, "", "")
            return None, (dz, artist.name if artist else "", rec.title)

    found, (dz_id, artist_name, title) = await asyncio.to_thread(local)
    if found is not None:
        return found
    dz = get_deezer_client()
    if not dz_id and artist_name and title:
        hit = await dz.find_track(primary_artist_name(artist_name), title)
        if hit and _normalize((hit.get("title") or "")).startswith(_normalize(title)[:12]):
            dz_id = str(hit.get("id") or "") or None
    track = await dz.track(dz_id) if dz_id else None
    preview = (track or {}).get("preview")
    return {"url": preview, "startMs": 0} if preview else None


async def warm_all() -> int:
    """Generátor Domů: předpočítá odemčená období (první výpočet roku zařazuje
    interprety do žánrů přes Deezer -- ať na to uživatel nečeká)."""
    periods = available_periods(g.home_user())
    done = 0
    for item in periods["years"] + [periods["decade"]]:
        if item["locked"]:
            continue
        await period_stats(g.home_user(), item["id"])
        done += 1
    return done
