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
    # Globální (owner `GLOBAL_PLAYLIST_OWNER`) snapshoty pro Domů, viz app/home.
    CHART = "CHART"
    GENRE = "GENRE"
    EDITORIAL = "EDITORIAL"
    # Osobní mixy generované z oblíbených/poslechů (Denní mix, Objevy týdne,
    # Na opakování, Návrat do minulosti), viz app/home/personal_mixes.py.
    PERSONAL_MIX = "PERSONAL_MIX"


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
    # Deezer album id -- dedup klíč pro vyhledávání/žebříčky z Deezeru, které
    # MBID nemají (MBID se dohledá líně, viz app/catalog/deezer_ingest.py).
    deezer_id: str | None = Field(default=None, index=True)
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
    deezer_id: str | None = Field(default=None, index=True)
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
    # Obrys hlasitosti pro vlnovku (app/loudness.py): base64 z
    # `WAVEFORM_BUCKETS` bajtů 0..255; `None` = neměřeno, "" = nejde změřit.
    waveform: str | None = None
    waveform_duration_ms: int | None = None
    # "Odebrat z knihovny" u skladby z uživatelovy vlastní složky (ta je
    # připojená jen pro čtení a soubory nemažeme) -- skladba zůstává
    # přehratelná, jen se neukazuje v knihovně.
    hidden_from_library: bool | None = None
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
    # Jen Domů (app/home): popisek karty, až 4 obaly pro mozaiku, sekce a do
    # kdy snapshot platí. Uživatelské playlisty je nechávají prázdné.
    description: str | None = None
    cover_urls: list[str] = Field(default_factory=list, sa_column=Column(JSON))
    section: str | None = Field(default=None, index=True)
    expires_at: datetime | None = None
    updated_at: datetime = Field(default_factory=utcnow)


class PlaylistItem(SQLModel, table=True):
    id: str = Field(default_factory=new_uuid, primary_key=True)
    playlist_id: str = Field(foreign_key="playlist.id", index=True)
    recording_id: str = Field(foreign_key="recording.id", index=True)
    position: int = 0
    added_at: datetime = Field(default_factory=utcnow)


GLOBAL_PLAYLIST_OWNER = "__global__"


class Listen(SQLModel, table=True):
    """Jeden poslech (scrobble) -- zapisuje ho klient, když skladba hrála aspoň
    polovinu délky nebo 4 minuty. Zdroj pro osobní mixy a zároveň fronta
    pro odeslání do ListenBrainz (`lb_submitted_at` je `None`, dokud se
    odeslání nepovede -- výpadek sítě/LB tak poslech neztratí)."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    recording_id: str = Field(foreign_key="recording.id", index=True)
    played_at: datetime = Field(default_factory=utcnow, index=True)
    duration_played_ms: int | None = None
    source: str | None = None
    # Odkud se přehrávání spustilo (cesta v appce: "/playlists/<id>",
    # "/library/liked", "/artists/<id>", "/releases/<id>") -- "Pokračovat v
    # poslechu" podle ní ukazuje i playlisty, ne jen alba.
    context: str | None = None
    lb_submitted_at: datetime | None = Field(default=None, index=True)
    lb_attempts: int = 0
    lb_error: str | None = None


class ListenLater(SQLModel, table=True):
    """"Poslechnout později" -- skladba, album nebo interpret, na které teď
    není nálada. Po poslechnutí se samo označí `listened_at` (viz
    app/listen_later.py) a přesune do "Poslechnuto"."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    kind: str  # track | album | artist
    target_id: str = Field(index=True)  # recording / release / artist id
    note: str | None = None
    # Odkud položka přišla: None = ručně, "shazam" = rozpoznáno v Open Shazamu.
    source: str | None = None
    added_at: datetime = Field(default_factory=utcnow, index=True)
    listened_at: datetime | None = Field(default=None, index=True)


class HomeSnapshot(SQLModel, table=True):
    """Poslední úspěšný výsledek jednoho generátoru Domů (seznam id alb pro
    "Nové vydání", čas posledního úspěšného běhu...) -- v DB, ne v Redisu, ať
    přežije restart a neúspěšný běh nikdy nesmaže poslední dobrá data."""

    key: str = Field(primary_key=True)
    payload: dict = Field(default_factory=dict, sa_column=Column(JSON))
    generated_at: datetime = Field(default_factory=utcnow)
