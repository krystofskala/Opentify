"""Nejposlouchanější skladby interpreta (jako Spotify/Apple Music nahoře na
stránce interpreta) -- i s počty poslechů.

Zdroje:
  1. ListenBrainz `popularity/top-recordings-for-artist/{mbid}` -- pořadí a
     počty poslechů komunity ListenBrainz (menší čísla než Spotify, ale
     pořadí oblíbenosti sedí). Vyžaduje token (LISTENBRAINZ_TOKEN).
  0. Last.fm `artist.getTopTracks` (je-li LASTFM_API_KEY) -- větší komunita
     než ListenBrainz, čísla blíž tomu, co lidé znají ze Spotify.
  2. Bez MBID nebo když LB nic nemá: Deezer `/artist/{id}/top` -- pořadí
     oblíbenosti bez počtů.

Skladby, které v katalogu ještě nejsou, se dohledají přes Deezer (interpret +
název) a převezmou. Výsledek (id skladeb + počty) se cachuje na 24 h.
"""

from __future__ import annotations

import asyncio
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


def _lastfm_key() -> str | None:
    return os.environ.get("LASTFM_API_KEY") or None


async def _lastfm_top(name: str) -> list[dict[str, Any]]:
    """[{title, listens}] seřazené podle oblíbenosti, nebo []."""
    key = _lastfm_key()
    if not key:
        return []
    try:
        resp = await _http.get(
            "https://ws.audioscrobbler.com/2.0/",
            params={
                "method": "artist.gettoptracks",
                "artist": name,
                "autocorrect": "1",
                "limit": str(LIMIT * 3),
                "api_key": key,
                "format": "json",
            },
        )
        data = resp.json() if resp.status_code == 200 else {}
    except (httpx.HTTPError, ValueError):
        return []
    tracks = ((data or {}).get("toptracks") or {}).get("track") or []
    out = []
    for t in tracks if isinstance(tracks, list) else []:
        title = t.get("name") or ""
        if not title or _VERSION.search(title):
            continue  # "(Live)", "- Acoustic"... -- chceme hlavní verze
        try:
            listens = int(t.get("playcount") or 0) or None
        except ValueError:
            listens = None
        out.append({"title": title, "listens": listens})
    return out


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


def _exact(text: str) -> str:
    import unicodedata

    text = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().casefold()
    return re.sub(r"\s+", " ", text).strip()


def _find_local(
    session: Session, artist_id: str, mbid: str | None, title: str, release_name: str | None = None
) -> Recording | None:
    if mbid:
        rec = session.exec(select(Recording).where(Recording.mbid == mbid)).first()
        if rec is not None:
            return rec
    # Přesně ta verze, kterou zdroj uvádí: stejný název (i se závorkami) a
    # stejné album. Stejné jméno má často desítky nahrávek (koncerty
    # z MusicBrainz) -- dřív vyhrála první v DB ("Ride (Live In Mexico City)").
    from app.models import Release

    exact_title = _exact(title)
    exact_release = _exact(release_name) if release_name else None
    same_title = [
        rec
        for rec in session.exec(select(Recording).where(Recording.artist_id == artist_id)).all()
        if _exact(rec.title) == exact_title
    ]
    # Skladby z jiných edic (pásky koncertů) jen, když jiná není -- jinak
    # by "jediná shoda" kvůli nim nikdy nevyšla.
    canonical = [rec for rec in same_title if not (rec.external_refs or {}).get("otherEdition")]
    same_title = canonical or same_title
    if exact_release is None:
        return same_title[0] if len(same_title) == 1 else None
    for rec in same_title:
        release = session.get(Release, rec.release_id) if rec.release_id else None
        if release is not None and _exact(release.title) == exact_release:
            return rec
    return None  # ta verze tu ještě není -- dohledá se přes Deezer


POOL_SIZE = 100


async def _deezer_top_pool(dz: Any, name: str, deezer_id: str | None) -> list[dict[str, Any]]:
    # `name`: celé jméno z katalogu; hledá se podle hlavního interpreta.
    """Až 100 nejposlouchanějších skladeb interpreta na Deezeru, [] když
    interpreta nenajde (jméno se páruje jen přesně, viz `trust_name`)."""
    try:
        if not deezer_id:
            found = await dz.search_artist(primary_artist_name(name), trust_name=False)
            match = next((a for a in found if _normalize(a.get("name", "")) == _normalize(name)), None)
            deezer_id = str(match["id"]) if match else None
        return (await dz.artist_top(deezer_id, POOL_SIZE) or []) if deezer_id else []
    except Exception:  # noqa: BLE001 -- jen zkratka, hledání níž to zvládne i bez ní
        return []


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
        return [{"id": rid, "listens": count or None, "source": "opentify"} for rid, count in rows]

    entries: list[dict[str, Any]] = []
    source: str | None = None
    lastfm = await _lastfm_top(primary_artist_name(name))
    if len(lastfm) >= 5:
        # Album každé skladby (track.getInfo) se dotáhne v `resolve` níž --
        # vybere se přesně ta verze, která se poslouchá (ne živá nahrávka se
        # stejným názvem).
        entries = [{"title": e["title"], "listens": e["listens"], "album_from_lastfm": True} for e in lastfm[: LIMIT + 3]]
        source = "lastfm"
    elif mbid:
        entries = [
            {
                "title": e.get("recording_name") or "",
                "mbid": e.get("recording_mbid"),
                "release": e.get("release_name"),
                "listens": e.get("total_listen_count"),
            }
            for e in await _lb_top(mbid)
        ]
        source = "listenbrainz"

    if entries:
        entries = [e for e in entries[: LIMIT * 2] if e.get("title")]
        artist_q = primary_artist_name(name)
        sem = asyncio.Semaphore(5)
        # Nejposlouchanější skladby interpreta na Deezeru (1 dotaz, i s alby):
        # skladba se stejným názvem I albem se vezme odtud a nemusí se
        # hledat -- dřív 2-3 hledání na skladbu za globálním limitem Deezeru.
        pool_task = asyncio.ensure_future(_deezer_top_pool(dz, name, deezer_id))

        async def lookup(entry: dict[str, Any]) -> dict[str, Any] | None:
            title = entry["title"]
            if entry.get("release"):
                hit = next(
                    (
                        t
                        for t in await pool_task
                        if _exact(t.get("title") or "") == _exact(title)
                        and _exact((t.get("album") or {}).get("title") or "") == _exact(entry["release"])
                        and str((t.get("album") or {}).get("id")) not in not_mine
                    ),
                    None,
                )
                if hit:
                    return hit
            async with sem:
                if entry.get("release"):
                    # Přesně ta verze: Deezer s názvem alba.
                    found = await dz.search(f'artist:"{artist_q}" track:"{title}" album:"{entry["release"]}"', 5)
                    track = next(
                        (
                            t
                            for t in (found or {}).get("data") or []
                            if _exact(t.get("title") or "") == _exact(title)
                            and _exact((t.get("album") or {}).get("title") or "") == _exact(entry["release"])
                        ),
                        None,
                    )
                    if track:
                        return track
                # Přesně stejný název skladby od toho interpreta (ne "(Live in ...)").
                found = await dz.search(f"{artist_q} {title}", 10)
                loose = (found or {}).get("data") or []
                track = next(
                    (
                        t
                        for t in loose
                        if _exact(t.get("title") or "") == _exact(title)
                        and _exact((t.get("artist") or {}).get("name") or "") == _exact(artist_q)
                    ),
                    None,
                )
                if track:
                    return track
                # Jako `dz.find_track`, ale volné hledání ("interpret název")
                # už máme výš -- o dotaz na skladbu méně za limitem Deezeru.
                return await dz.find_track(artist_q, title, loose=loose)

        async def resolve(entry: dict[str, Any]) -> tuple[str | None, dict[str, Any] | None]:
            """Každá skladba sama: album z Last.fm -> místní katalog -> Deezer.
            Dřív se čekalo na alba VŠECH skladeb (Last.fm 4 req/s, ~3,5 s)
            a teprve pak začal Deezer -- studená stránka interpreta 7-10 s."""
            if entry.pop("album_from_lastfm", False):
                from app.catalog.lastfm import track_album

                entry["release"] = await track_album(artist_q, entry["title"])
            with Session(engine) as session:
                rec = _find_local(session, artist_id, entry.get("mbid"), entry["title"], entry.get("release"))
                if rec is not None:
                    return rec.id, None
            return None, await lookup(entry)

        resolved = await asyncio.gather(*(resolve(e) for e in entries))
        local_ids: list[str | None] = [rid for rid, _ in resolved]
        with Session(engine) as session:
            for i, (_, track) in enumerate(resolved):
                if track:
                    rec = ingest_track_with_context(session, track)
                    session.flush()
                    local_ids[i] = rec.id if rec is not None else None
            session.commit()
        for entry, rec_id in zip(entries, local_ids):
            if rec_id and rec_id not in seen:
                seen.add(rec_id)
                out.append({"id": rec_id, "listens": entry.get("listens"), "source": source})
            if len(out) >= LIMIT:
                break

    if len(out) < 5:
        # Doplnit z Deezeru (pořadí oblíbenosti, bez počtů).
        tracks = (await _deezer_top_pool(dz, name, deezer_id))[:LIMIT]
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


def by_listens(items: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Seřazeno podle zobrazeného počtu přehrání jako ve Spotify. Last.fm
    řadí podle posluchačů, ale appka ukazuje přehrání -- seznam pak vypadal
    neseřazeně (audit 7. 10.: Maalouf). Bez počtu na konec, v pořadí zdroje."""
    return sorted(items, key=lambda i: -(i.get("listens") or 0) if i.get("listens") else 1)


async def artist_top_tracks(artist_id: str) -> list[dict[str, Any]]:
    """Seznam RecordingOut (dict) s `listenCount`."""
    from app.home.service import _recording_out

    async def build() -> dict[str, Any]:
        return {"items": await _ids_and_counts(artist_id)}

    cached = await cached_json(f"artist-top:v5:{artist_id}", TOP_TTL_S, build, is_empty=lambda v: not v.get("items"))
    result = []
    with Session(engine) as session:
        for item in by_listens(cached.get("items", [])):
            rec = session.get(Recording, item["id"])
            if rec is None:
                continue
            out = _recording_out(session, rec)
            out.listen_count = item.get("listens")
            out.listen_source = item.get("source") if item.get("listens") else None
            result.append(out.model_dump(mode="json", by_alias=True))
    return result
