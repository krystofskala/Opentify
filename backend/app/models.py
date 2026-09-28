"""SQLModel entity pro provisioning jádro a katalog (Artist/Release/Recording).

Katalogové entity jsou lokální cache toho, co Catalog Service (app/catalog/)
zjistí z MusicBrainz/Deezer — `mbid`/`deezer_id` jsou vazby na externí zdroj,
`id` je náš stabilní lokální identifikátor, na který se váže MediaAsset a
ProvisioningJob. Provisioning logika sama na obsahu Recording nezávisí,
potřebuje jen existující `recording_id`.
"""

from __future__ import annotations

import enum
import uuid
from datetime import datetime

from sqlalchemy import JSON, Column
from sqlmodel import Field, SQLModel

from app.utils import utcnow


def new_uuid() -> str:
    return str(uuid.uuid4())


class MediaAssetStatus(str, enum.Enum):
    MISSING = "MISSING"
    QUEUED = "QUEUED"
    DOWNLOADING = "DOWNLOADING"
    TRANSCODING = "TRANSCODING"
    AVAILABLE = "AVAILABLE"
    FAILED = "FAILED"


class ProvisioningJobStatus(str, enum.Enum):
    PENDING = "PENDING"
    RUNNING = "RUNNING"
    SUCCEEDED = "SUCCEEDED"
    FAILED = "FAILED"
    CANCELLED = "CANCELLED"


class PlaylistKind(str, enum.Enum):
    USER = "USER"
    GENERATED_RECOMMENDATION = "GENERATED_RECOMMENDATION"
    RADIO = "RADIO"


class Artist(SQLModel, table=True):
    id: str = Field(default_factory=new_uuid, primary_key=True)
    mbid: str | None = Field(default=None, index=True, unique=True)
    deezer_id: str | None = Field(default=None, index=True)
    name: str
    sort_name: str | None = None
    # ISO 3166-1 alpha-2 (např. "CZ") -- z MusicBrainz `/artist/{mbid}` lookupu
    # (top-level `country` pole, žádný extra `inc=` navíc), viz
    # `CatalogService._enrich_artist_country`. `None`, dokud se nedoplní.
    country: str | None = Field(default=None, index=True)
    images: list[str] = Field(default_factory=list, sa_column=Column(JSON))
    external_refs: dict = Field(default_factory=dict, sa_column=Column(JSON))
    updated_at: datetime = Field(default_factory=utcnow)


class Release(SQLModel, table=True):
    """Album/EP/singl — odpovídá MusicBrainz release-group (abstraktní seskupení
    edic), ne konkrétní release. Tracklist se dotahuje z reprezentativní
    release edice, viz app/catalog/musicbrainz.py."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    mbid: str | None = Field(default=None, index=True, unique=True)
    artist_id: str = Field(foreign_key="artist.id", index=True)
    title: str
    release_date: str | None = None  # ISO string; MB má často jen rok nebo rok-měsíc
    release_type: str = "album"  # album|ep|single|compilation
    # Jména MusicBrainz genre tagů (`inc=genres`, viz `CatalogService.
    # _ingest_release_group_json`/`_enrich_release_genres`) -- jen `name`
    # řetězce, ne celé `{id,name,count}` objekty, stejně jako `images`.
    genres: list[str] = Field(default_factory=list, sa_column=Column(JSON))
    images: list[str] = Field(default_factory=list, sa_column=Column(JSON))
    external_refs: dict = Field(default_factory=dict, sa_column=Column(JSON))
    updated_at: datetime = Field(default_factory=utcnow)


class Recording(SQLModel, table=True):
    id: str = Field(default_factory=new_uuid, primary_key=True)
    mbid: str | None = Field(default=None, index=True, unique=True)
    release_id: str | None = Field(default=None, foreign_key="release.id", index=True)
    artist_id: str | None = Field(default=None, foreign_key="artist.id", index=True)
    title: str
    duration_ms: int | None = None
    isrc: str | None = Field(default=None, index=True)
    track_number: int | None = None
    external_refs: dict = Field(default_factory=dict, sa_column=Column(JSON))
    updated_at: datetime = Field(default_factory=utcnow)


class MediaAsset(SQLModel, table=True):
    """1:1 s Recording — popisuje stav dat *na disku*, ne stav práce k nim vedoucí."""

    recording_id: str = Field(foreign_key="recording.id", primary_key=True)
    status: MediaAssetStatus = Field(default=MediaAssetStatus.MISSING)
    storage_path: str | None = None
    format: str | None = None
    bitrate_kbps: int | None = None
    filesize_bytes: int | None = None
    checksum_sha256: str | None = None
    source_provider: str | None = None
    last_error: str | None = None
    # Hlasitostní korekce v dB k cíli -14 LUFS (viz app/loudness.py) -- `None`
    # = ještě neanalyzováno, klient pak hraje bez korekce.
    loudness_gain_db: float | None = None
    updated_at: datetime = Field(default_factory=utcnow)


class ProvisioningJob(SQLModel, table=True):
    """Popisuje stav *práce* vedoucí k obstarání — odděleně od MediaAsset,
    aby retry/attempts nekomplikovaly stav "je to přehratelné?"."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    recording_id: str = Field(foreign_key="recording.id", index=True)
    requested_by_user_id: str
    requested_by_device_id: str | None = None
    priority: int = 0
    status: ProvisioningJobStatus = Field(default=ProvisioningJobStatus.PENDING)
    attempts: int = 0
    max_attempts: int = 3
    created_at: datetime = Field(default_factory=utcnow, index=True)
    started_at: datetime | None = None
    finished_at: datetime | None = None
    error_message: str | None = None


class Playlist(SQLModel, table=True):
    id: str = Field(default_factory=new_uuid, primary_key=True)
    owner_user_id: str = Field(index=True)
    title: str
    kind: PlaylistKind = Field(default=PlaylistKind.USER)
    source: str | None = Field(default=None, index=True)  # např. "listenbrainz:daily-jams"
    generated_at: datetime | None = None
    is_pinned: bool = False
    updated_at: datetime = Field(default_factory=utcnow)


class PlaylistItem(SQLModel, table=True):
    id: str = Field(default_factory=new_uuid, primary_key=True)
    playlist_id: str = Field(foreign_key="playlist.id", index=True)
    recording_id: str = Field(foreign_key="recording.id", index=True)
    position: int = 0
    added_at: datetime = Field(default_factory=utcnow)
