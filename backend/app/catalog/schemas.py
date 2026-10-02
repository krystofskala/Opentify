"""Response DTO pro Catalog Service — 1:1 s `components.schemas` v
docs/openapi.yaml. Pole jsou psaná snake_case (pythonic), ale serializují se
jako camelCase (`by_alias=True`), aby JSON přes drát odpovídal spec."""

from __future__ import annotations

from enum import Enum

from pydantic import BaseModel, ConfigDict


def _to_camel(name: str) -> str:
    first, *rest = name.split("_")
    return first + "".join(part.capitalize() for part in rest)


class CamelModel(BaseModel):
    model_config = ConfigDict(alias_generator=_to_camel, populate_by_name=True)


class Availability(str, Enum):
    AVAILABLE = "available"
    PROVISIONABLE = "provisionable"
    UNAVAILABLE = "unavailable"


class ArtistOut(CamelModel):
    id: str
    mbid: str | None = None
    deezer_id: str | None = None
    name: str
    sort_name: str | None = None
    images: list[str] = []
    # Široká fotka interpreta pro hlavičku (fanart.tv `artistbackground`),
    # `images` zůstává čtvercová fotka. `None`, dokud není/nejde doplnit.
    banner_url: str | None = None


class ReleaseOut(CamelModel):
    id: str
    mbid: str | None = None
    artist_id: str
    title: str
    release_date: str | None = None
    release_type: str
    images: list[str] = []
    # Jen u `/artists/{id}/rarities`: "demo" | "live" | "bootleg" -- materiál
    # bez oficiálního vydání (viz CatalogService.get_rarities).
    rarity: str | None = None
    # Vlastní poznámka k albu (obsazení apod.) -- `external_refs["notes"]`.
    notes: str | None = None
    # Přidané ručně (odkaz z YouTube / ručně přiřazené) -- jde smazat.
    imported: bool = False
    # Jen z YouTube (neoficiální / ztracené album) -- štítek v diskografii.
    youtube_only: bool = False


class RecordingOut(CamelModel):
    id: str
    mbid: str | None = None
    release_id: str | None = None
    artist_id: str | None = None
    # Denormalizované jméno interpreta -- bez tohohle nemá klient u smíšených
    # seznamů (Domů, Knihovna, Oblíbené, playlisty) odkud vzít jméno k
    # zobrazení, jen `artist_id`. Doplňkové pole mimo strict OpenAPI schéma,
    # stejně jako `preview_url`/`listen_count` níž.
    artist_name: str | None = None
    title: str
    duration_ms: int | None = None
    isrc: str | None = None
    track_number: int | None = None
    availability: Availability
    preview_url: str | None = None  # Deezer 30s náhled, doplňkové pole mimo strict OpenAPI schéma
    listen_count: int | None = None  # jen /recommendations/trending|community, viz RecommendationService
    # Odkud `listen_count` je ("lastfm" | "listenbrainz" | "opentify") -- klient to píše k číslu.
    listen_source: str | None = None


class DiscographyOut(CamelModel):
    artist: ArtistOut
    releases: list[ReleaseOut]


class ArtistBioOut(CamelModel):
    bio: str | None = None
    related_artists: list[ArtistOut] = []
    # U člověka kapely a projekty, ve kterých hraje/hrál; u kapely členové
    # (současní napřed). Z MusicBrainz "member of band".
    bands: list[ArtistOut] = []
    members: list[ArtistOut] = []


class SearchResponse(CamelModel):
    query: str
    total: int
    results: list[dict]  # entityType + zploštělé pole z Artist/Release/RecordingOut
