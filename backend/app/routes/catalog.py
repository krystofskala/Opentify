"""REST routy pro globální katalog — `/catalog/*` z docs/openapi.yaml.

Tenká vrstva: veškerá logika (MB/Deezer, cache, upsert, availability) žije
v `app.catalog.service.CatalogService`, routy jen validují vstup a mapují
`None`/prázdný výsledek na 404.
"""

from __future__ import annotations

import re

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlmodel import Session

from app.auth import get_current_user, require_admin
from app.catalog.availability import compute_availability, resolve_artist_name
from app.catalog.deezer import DeezerClient, get_deezer_client
from app.catalog.musicbrainz import MusicBrainzClient, MusicBrainzError, get_musicbrainz_client
from app.catalog.service import CatalogService
from app.catalog.schemas import RecordingOut
from app.catalog.cache import cached_json_swr
from app.db import engine, get_session
from app.models import Artist, Recording, Release

catalog_router = APIRouter(prefix="/catalog", tags=["catalog"])


def get_catalog_service(
    session: Session = Depends(get_session),
    mb_client: MusicBrainzClient = Depends(get_musicbrainz_client),
    dz_client: DeezerClient = Depends(get_deezer_client),
) -> CatalogService:
    return CatalogService(session, mb_client, dz_client)


@catalog_router.get("/search")
async def search_catalog(
    q: str = Query(..., min_length=1),
    type: str | None = Query(default=None, alias="type", pattern="^(artist|release|recording)$"),
    limit: int = Query(default=20, ge=1, le=100),
    offset: int = Query(default=0, ge=0),
    service: CatalogService = Depends(get_catalog_service),
    _current=Depends(get_current_user),
):
    try:
        found = await service.search(q, type, limit, offset)
        # Překlep ("bily strngs"): Deezer skoro nic -- Last.fm opraví jméno
        # interpreta a hledá se znovu (cache 7 dní, takže 3 typy = 1 dotaz).
        if offset == 0 and len(q.strip()) >= 3 and len(found.get("results") or []) < 3:
            from app.catalog.lastfm import artist_correction
            from app.catalog.service import _normalize_query

            fixed = await artist_correction(q)
            if fixed and _normalize_query(fixed) != _normalize_query(q):
                better = await service.search(fixed, type, limit, 0)
                ids = {r.get("id") for r in better.get("results") or []}
                merged = (better.get("results") or []) + [
                    r for r in found.get("results") or [] if r.get("id") not in ids
                ]
                return {**better, "query": q, "results": merged[:limit], "total": len(merged), "didYouMean": fixed}
        return found
    except MusicBrainzError:
        # Odlišuje "MusicBrainz momentálně nedostupný/rate-limit" od
        # skutečného "nic takového neexistuje" (prázdný `results`) -- klient
        # na 503 může nabídnout "zkus to znovu", místo aby to tiše vypadalo
        # jako neúspěšné hledání.
        raise HTTPException(status_code=503, detail="MusicBrainz momentálně nedostupný, zkus to znovu za chvíli")


@catalog_router.get("/artists/{artist_id}")
async def get_artist(
    artist_id: str,
    service: CatalogService = Depends(get_catalog_service),
    _current=Depends(get_current_user),
):
    artist = await service.get_artist(artist_id)
    if artist is None:
        raise HTTPException(status_code=404, detail="interpret nenalezen")
    return artist.model_dump(by_alias=True)


@catalog_router.get("/artists/{artist_id}/top-tracks")
async def get_artist_top_tracks(artist_id: str, _current=Depends(get_current_user)):
    """Nejposlouchanější skladby interpreta s počty poslechů (viz
    app/catalog/top_tracks.py)."""
    from app.catalog.top_tracks import artist_top_tracks

    return await artist_top_tracks(artist_id)


def _exact(title: str) -> str:
    """Název pro přesné porovnání: jen velikost písmen, diakritika a mezery."""
    import unicodedata

    text = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode().casefold()
    return re.sub(r"\s+", " ", text).strip()


@catalog_router.get("/artists/{artist_id}/stats")
async def get_artist_stats(artist_id: str, _current=Depends(get_current_user)):
    """Last.fm: počet posluchačů + nejposlouchanější vydání (id našich
    vydání v pořadí oblíbenosti) -- "Populární vydání" jako na Spotify."""
    from sqlmodel import Session, select

    from app.catalog import lastfm
    from app.catalog.artwork import primary_artist_name
    from app.db import engine
    from app.models import Artist, Release

    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        if artist is None:
            raise HTTPException(status_code=404, detail="interpret nenalezen")
        if (artist.mbid or "").startswith("own:"):
            return {"listeners": None, "playcount": None, "popularReleaseIds": []}
        name = primary_artist_name(artist.name)
        releases = session.exec(select(Release).where(Release.artist_id == artist_id)).all()
        # Přesný název (i se závorkami) -- Last.fm počítá každou verzi zvlášť
        # ("Heathens" vs "Heathens (DISTO Remix)"), bere se přesně ta, která
        # je nejposlouchanější.
        by_title: dict[str, list[Release]] = {}
        for r in releases:
            by_title.setdefault(_exact(r.title), []).append(r)
    info = await lastfm.artist_info(name)
    albums = await lastfm.top_albums(name, limit=40)
    popular: list[str] = []
    for album in albums:
        # Stejný přesný název víckrát (duplicitní záznam) -- nejstarší.
        candidates = sorted(by_title.get(_exact(album["title"])) or [], key=lambda r: r.release_date or "9999")
        if candidates and candidates[0].id not in popular:
            popular.append(candidates[0].id)
        if len(popular) >= 10:
            break
    return {
        "listeners": (info or {}).get("listeners"),
        "playcount": (info or {}).get("playcount"),
        "popularReleaseIds": popular,
    }


@catalog_router.get("/artists/{artist_id}/rarities")
async def get_rarities(
    artist_id: str,
    service: CatalogService = Depends(get_catalog_service),
    _current=Depends(get_current_user),
):
    """Dema, živáky a bootlegy bez oficiálního vydání (sekce "Nevydané a
    vzácné" na stránce interpreta)."""
    try:
        items = await service.get_rarities(artist_id)
    except MusicBrainzError:
        raise HTTPException(status_code=503, detail="MusicBrainz momentálně nedostupný, zkus to za chvíli znovu")
    if items is None:
        raise HTTPException(status_code=404, detail="interpret nenalezen")
    return {"items": [i.model_dump(by_alias=True) for i in items]}


@catalog_router.get("/artists/{artist_id}/discography")
async def get_discography(
    artist_id: str,
    release_type: str | None = Query(
        default=None, alias="releaseType", pattern="^(album|ep|single|compilation)$"
    ),
    _current=Depends(get_current_user),
):
    # Stale-while-revalidate: hotová diskografie hned, obnova na pozadí, je-li
    # starší než den. Dřív se po hodině (cache MB hledání) skládala znovu --
    # MB 1 dotaz/s, víc stránek u velkých interpretů + Deezer = stránka
    # interpreta se otevírala i několik sekund (živě nahlášeno).
    async def build():
        # Vlastní DB session -- obnova na pozadí běží i po odeslání odpovědi.
        with Session(engine) as session:
            service = CatalogService(session, get_musicbrainz_client(), get_deezer_client())
            discography = await service.get_discography(artist_id, release_type)
            return discography.model_dump(mode="json", by_alias=True) if discography else None

    data = await cached_json_swr(f"discography:v1:{artist_id}:{release_type}", 24 * 60 * 60, build)
    if data is None:
        raise HTTPException(status_code=404, detail="interpret nenalezen")
    return data


@catalog_router.post("/artists/{artist_id}/releases/{release_id}/not-artist")
async def mark_release_not_artist(
    artist_id: str,
    release_id: str,
    session: Session = Depends(get_session),
    _current=Depends(require_admin),
):
    """"Nepatří k interpretovi": Deezer (i MB) občas přimíchá alba
    stejnojmenné cizí kapely. Album se z diskografie interpreta natrvalo
    vyřadí a přesune ke zvláštnímu stejnojmennému interpretovi, ať jeho
    skladby nevisí pod špatnou kapelou."""
    from sqlmodel import select

    from app.redis_bus import get_redis

    artist = session.get(Artist, artist_id)
    release = session.get(Release, release_id)
    if artist is None or release is None:
        raise HTTPException(status_code=404, detail="interpret nebo album nenalezeno")
    refs = dict(artist.external_refs or {})
    not_mine = list(refs.get("notMine") or [])
    for key in (release.id, release.deezer_id):
        if key and key not in not_mine:
            not_mine.append(key)
    refs["notMine"] = not_mine
    artist.external_refs = refs
    session.add(artist)
    if release.artist_id == artist.id:
        homonym = next(
            (
                a
                for a in session.exec(select(Artist).where(Artist.name == artist.name)).all()
                if (a.external_refs or {}).get("homonymOf") == artist.id
            ),
            None,
        )
        if homonym is None:
            homonym = Artist(name=artist.name, external_refs={"homonymOf": artist.id})
            session.add(homonym)
            session.flush()
        release.artist_id = homonym.id
        session.add(release)
        for rec in session.exec(
            select(Recording).where(Recording.release_id == release.id, Recording.artist_id == artist.id)
        ).all():
            rec.artist_id = homonym.id
            session.add(rec)
    session.commit()
    r = get_redis()
    keys = [k async for k in r.scan_iter(match=f"vault:catalog:cache:*{artist_id}*")]
    if keys:
        await r.delete(*keys)
    return {"artistId": artist_id, "releaseId": release_id, "notMine": not_mine}


@catalog_router.get("/artists/{artist_id}/bio")
async def get_artist_bio(
    artist_id: str,
    service: CatalogService = Depends(get_catalog_service),
    _current=Depends(get_current_user),
):
    bio = await service.get_artist_bio(artist_id)
    if bio is None:
        raise HTTPException(status_code=404, detail="interpret nenalezen")
    return bio.model_dump(by_alias=True)


@catalog_router.get("/artists/{artist_id}/support")
async def get_artist_support(
    artist_id: str,
    service: CatalogService = Depends(get_catalog_service),
    _current=Depends(get_current_user),
):
    data = await service.get_artist_support(artist_id)
    if data is None:
        raise HTTPException(status_code=404, detail="interpret nenalezen")
    return data


@catalog_router.get("/releases/{release_id}")
async def get_release(
    release_id: str,
    service: CatalogService = Depends(get_catalog_service),
    _current=Depends(get_current_user),
):
    release = await service.get_release(release_id)
    if release is None:
        raise HTTPException(status_code=404, detail="album nenalezen")
    return release.model_dump(by_alias=True)


@catalog_router.get("/releases/{release_id}/tracks")
async def get_release_tracks(
    release_id: str,
    service: CatalogService = Depends(get_catalog_service),
    _current=Depends(get_current_user),
):
    tracks = await service.get_release_tracks(release_id)
    if tracks is None:
        raise HTTPException(status_code=404, detail="album nenalezen")
    return [t.model_dump(by_alias=True) for t in tracks]


@catalog_router.get("/recordings/{recording_id}")
def get_recording(
    recording_id: str,
    session: Session = Depends(get_session),
    _current=Depends(get_current_user),
):
    """Jedna nahrávka z lokálního katalogu -- pro samostatnou stránku detailu
    skladby (`/tracks/:id` na klientu). Bez MB volání: nahrávka, na kterou
    se dá prokliknout, už v katalogu je (upsertla ji search/tracklist/recs)."""
    recording = session.get(Recording, recording_id)
    if recording is None:
        raise HTTPException(status_code=404, detail="skladba nenalezena")
    return RecordingOut(
        id=recording.id,
        mbid=recording.mbid,
        release_id=recording.release_id,
        artist_id=recording.artist_id,
        artist_name=resolve_artist_name(session, recording.artist_id),
        title=recording.title,
        duration_ms=recording.duration_ms,
        isrc=recording.isrc,
        track_number=recording.track_number,
        availability=compute_availability(session, recording.id),
        preview_url=recording.external_refs.get("previewUrl"),
    ).model_dump(by_alias=True)
