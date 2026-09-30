"""REST routy pro globální katalog — `/catalog/*` z docs/openapi.yaml.

Tenká vrstva: veškerá logika (MB/Deezer, cache, upsert, availability) žije
v `app.catalog.service.CatalogService`, routy jen validují vstup a mapují
`None`/prázdný výsledek na 404.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends, HTTPException, Query
from sqlmodel import Session

from app.auth import get_current_user
from app.catalog.availability import compute_availability, resolve_artist_name
from app.catalog.deezer import DeezerClient, get_deezer_client
from app.catalog.musicbrainz import MusicBrainzClient, MusicBrainzError, get_musicbrainz_client
from app.catalog.service import CatalogService
from app.catalog.schemas import RecordingOut
from app.catalog.cache import cached_json_swr
from app.db import engine, get_session
from app.models import Recording

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
        return await service.search(q, type, limit, offset)
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
