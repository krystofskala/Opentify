"""Nejposlouchanější skladby interpreta (jako Spotify/Apple Music nahoře na
stránce interpreta) -- i s počty poslechů.

Zdroje:
  1. ListenBrainz `popularity/top-recordings-for-artist/{mbid}` -- pořadí a
     počty poslechů komunity ListenBrainz (menší čísla než Spotify, ale
     pořadí oblíbenosti sedí). Vyžaduje token (LISTENBRAINZ_TOKEN).
  2. Bez MBID nebo když LB nic nemá: Deezer `/artist/{id}/top` -- pořadí
     oblíbenosti bez počtů.

Skladby, které v katalogu ještě nejsou, se dohledají přes Deezer (interpret +
název) a převezmou. Výsledek (id skladeb + počty) se cachuje na 24 h.
"""

from __future__ import annotations

import os
import re
from typing import Any

import httpx
from sqlmodel import Session, select

from app.catalog.artwork import _normalize, primary_artist_name
from app.catalog.cache import cached_json
from app.catalog.deezer import get_deezer_client
from app.catalog.deezer_ingest import ingest_track_with_context
from app.db import engine
from app.models import Artist, Recording

TOP_TTL_S = 24 * 60 * 60
LIMIT = 10

_http = httpx.AsyncClient(timeout=10.0)


def _token() -> str | None:
    return os.environ.get("LISTENBRAINZ_TOKEN") or None


async def _lb_top(artist_mbid: str) -> list[dict[str, Any]]:
    token = _token()
    if not token or artist_mbid.startswith("own:"):  # vlastní interpret
        return []
    try:
        resp = await _http.get(
            f"https://api.listenbrainz.org/1/popularity/top-recordings-for-artist/{artist_mbid}",
            headers={"Authorization": f"Token {token}"},
        )
        data = resp.json() if resp.status_code == 200 else []
    except (httpx.HTTPError, ValueError):
        return []
    return data if isinstance(data, list) else []


_VERSION = re.compile(r"\b(live|instrumental|acoustic|remix|demo|karaoke|unplugged|session|edit|version)\b|\d{4}-\d{2}", re.I)


def _find_local(
    session: Session, artist_id: str, mbid: str | None, title: str, release_name: str | None = None
) -> Recording | None:
    if mbid:
        rec = session.exec(select(Recording).where(Recording.mbid == mbid)).first()
        if rec is not None:
            return rec
    # Stejné jméno má často desítky nahrávek (koncerty z MusicBrainz) --
    # `_normalize` závorky zahazuje, takže "Ride (Live In Mexico City)" se
    # rovnalo "Ride" a vyhrála první v DB. Přednost: stejné album, přesný
    # název, ne živá/instrumentální verze.
    from app.models import Release

    wanted = _normalize(title)
    exact = title.strip().casefold()
    wanted_release = _normalize(release_name or "")
    best: tuple[int, Recording] | None = None
    for rec in session.exec(select(Recording).where(Recording.artist_id == artist_id)).all():
        if _normalize(rec.title) != wanted:
            continue
        release = session.get(Release, rec.release_id) if rec.release_id else None
        release_title = release.title if release else ""
        score = 0
        if wanted_release and _normalize(release_title) == wanted_release:
            score += 4
        if rec.title.strip().casefold() == exact:
            score += 2
        if _VERSION.search(rec.title) and not _VERSION.search(title):
            score -= 3
        if _VERSION.search(release_title) and not _VERSION.search(release_name or ""):
            score -= 2
        if best is None or score > best[0]:
            best = (score, rec)
    if best is None or best[0] < 0:
        return None  # jen jiné verze -- radši dohledat přes Deezer
    return best[1]


async def _ids_and_counts(artist_id: str) -> list[dict[str, Any]]:
    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None:
            return []
        mbid, name, deezer_id = artist.mbid, artist.name, artist.deezer_id
        not_mine = set((artist.external_refs or {}).get("notMine") or [])

    out: list[dict[str, Any]] = []
    seen: set[str] = set()
    dz = get_deezer_client()

    if (mbid or "").startswith("own:"):
        # Vlastní interpret: nejposlouchanější z poslechů v appce, nic online.
        from sqlalchemy import func

        from app.models import Listen

        with Session(engine) as session:
            rows = session.exec(
                select(Recording.id, func.count(Listen.id))
                .join(Listen, Listen.recording_id == Recording.id, isouter=True)
                .where(Recording.artist_id == artist_id)
                .group_by(Recording.id)
                .order_by(func.count(Listen.id).desc())
                .limit(LIMIT)
            ).all()
        return [{"id": rid, "listens": count or None} for rid, count in rows]

    if mbid:
        for entry in (await _lb_top(mbid))[: LIMIT * 2]:
            title = entry.get("recording_name") or ""
            if not title:
                continue
            with Session(engine) as session:
                rec = _find_local(session, artist_id, entry.get("recording_mbid"), title, entry.get("release_name"))
                rec_id = rec.id if rec is not None else None
            if rec_id is None:
                track = await dz.find_track(primary_artist_name(name), title)
                if track:
                    with Session(engine) as session:
                        rec = ingest_track_with_context(session, track)
                        session.commit()
                        rec_id = rec.id if rec is not None else None
            if rec_id and rec_id not in seen:
                seen.add(rec_id)
                out.append({"id": rec_id, "listens": entry.get("total_listen_count")})
            if len(out) >= LIMIT:
                break

    if len(out) < 5:
        # Doplnit z Deezeru (pořadí oblíbenosti, bez počtů).
        if not deezer_id:
            found = await dz.search_artist(primary_artist_name(name), trust_name=False)
            match = next((a for a in found if _normalize(a.get("name", "")) == _normalize(name)), None)
            deezer_id = str(match["id"]) if match else None
        tracks = await dz.artist_top(deezer_id, LIMIT) if deezer_id else None
        for track in tracks or []:
            if str((track.get("album") or {}).get("id")) in not_mine:
                continue  # album stejnojmenného cizího interpreta
            with Session(engine) as session:
                rec = ingest_track_with_context(session, track)
                session.commit()
                rec_id = rec.id if rec is not None else None
            if rec_id and rec_id not in seen:
                seen.add(rec_id)
                out.append({"id": rec_id, "listens": None})
            if len(out) >= LIMIT:
                break
    return out


async def artist_top_tracks(artist_id: str) -> list[dict[str, Any]]:
    """Seznam RecordingOut (dict) s `listenCount`."""
    from app.home.service import _recording_out

    async def build() -> dict[str, Any]:
        return {"items": await _ids_and_counts(artist_id)}

    cached = await cached_json(f"artist-top:v2:{artist_id}", TOP_TTL_S, build, is_empty=lambda v: not v.get("items"))
    result = []
    with Session(engine) as session:
        for item in cached.get("items", []):
            rec = session.get(Recording, item["id"])
            if rec is None:
                continue
            out = _recording_out(session, rec)
            out.listen_count = item.get("listens")
            result.append(out.model_dump(mode="json", by_alias=True))
    return result
