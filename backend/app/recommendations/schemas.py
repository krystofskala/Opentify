"""Response DTO pro Recommendation Service — 1:1 s `Playlist`/`PlaylistDetail`
v docs/openapi.yaml. Používá stejný `CamelModel`/`RecordingOut` jako Catalog
Service, aby doporučené a katalogové nahrávky vypadaly z pohledu klienta
identicky."""

from __future__ import annotations

from datetime import datetime

from app.catalog.schemas import CamelModel, RecordingOut
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
