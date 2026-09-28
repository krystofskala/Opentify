"""Response DTO pro Recommendation Service — 1:1 s `Playlist`/`PlaylistDetail`
v docs/openapi.yaml. Používá stejný `CamelModel`/`RecordingOut` jako Catalog
Service, aby doporučené a katalogové nahrávky vypadaly z pohledu klienta
identicky."""

from __future__ import annotations

from datetime import datetime

from app.catalog.schemas import ArtistOut, CamelModel, RecordingOut
from app.models import PlaylistKind


class PlaylistOut(CamelModel):
    id: str
    title: str
    kind: PlaylistKind
    source: str | None = None
    generated_at: datetime | None = None
    item_count: int


class PlaylistDetailOut(PlaylistOut):
    items: list[RecordingOut]


class YearInReviewOut(CamelModel):
    """`GET /recommendations/year-in-review` -- viz
    `RecommendationService.year_in_review`. `range` říká klientovi, jaké
    okno LB stats reálně pokrývají (`year` = posledních 12 měsíců, ne nutně
    kalendářní rok -- ListenBrainz jiné dělení nenabízí), ať appka
    neslibuje přesnost, kterou zdroj dat nemá."""

    range: str
    total_listens: int
    top_tracks: list[RecordingOut]
    top_artists: list[ArtistOut]
