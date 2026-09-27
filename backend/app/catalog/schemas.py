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


class ReleaseOut(CamelModel):
    id: str
    mbid: str | None = None
    artist_id: str
    title: str
    release_date: str | None = None
    release_type: str
    images: list[str] = []


class RecordingOut(CamelModel):
    id: str
    mbid: str | None = None
    release_id: str | None = None
    artist_id: str | None = None
    title: str
    duration_ms: int | None = None
    isrc: str | None = None
    track_number: int | None = None
    availability: Availability
    preview_url: str | None = None  # Deezer 30s náhled, doplňkové pole mimo strict OpenAPI schéma
    listen_count: int | None = None  # jen /recommendations/trending|community, viz RecommendationService


class DiscographyOut(CamelModel):
    artist: ArtistOut
    releases: list[ReleaseOut]


class SearchResponse(CamelModel):
    query: str
    total: int
    results: list[dict]  # entityType + zploštělé pole z Artist/Release/RecordingOut
