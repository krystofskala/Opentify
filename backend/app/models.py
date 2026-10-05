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

from app.secret_box import EncryptedStr
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
    # Kdy byla skladba poprvé k dispozici (Knihovna › řazení "Přidáno").
    # `updated_at` se mění při každém přetagování / měření hlasitosti.
    available_at: datetime | None = None
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
    # Pro statistiky (app/tools/download_stats.py): odkud se to vzalo,
    # interaktivně (uživatel čeká) / na pozadí.
    source_provider: str | None = None
    audio_format: str | None = None
    interactive: bool | None = None


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
    # Kdo skladbu přidal (společné playlisty).
    added_by: str | None = None


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
    # Last.fm scrobble -- jen profil s připojeným vlastním účtem.
    lastfm_submitted_at: datetime | None = None
    lastfm_attempts: int | None = None


class PlayEvent(SQLModel, table=True):
    """Každé přehrání skladby i s tím, jak skončilo -- dohráno, přeskočeno,
    přepnuto v půlce, zastaveno. `Listen` je jen to, co se počítá jako poslech
    (polovina / 4 min); tady je i to ostatní, aby šlo měřit, jestli mixy
    sedí (podíl brzkých přeskočení, dokončení) a učit doporučování.

    Zdroj zatím server ze stavu Opentify Connect (app/connect_listens.py), takže
    funguje i se staršími buildy appky."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    recording_id: str = Field(index=True)
    started_at: datetime = Field(index=True)
    ended_at: datetime
    played_ms: int = 0
    duration_ms: int | None = None
    # completed | skipped (do 30 s a čtvrtiny) | next (přepnuto později)
    # | stopped (zastaveno / zařízení zmizelo)
    end_reason: str = Field(index=True)
    # Název fronty z appky ("Denní mix 1", album, interpret...) a když
    # odpovídá playlistu profilu, i jeho id a jestli je generovaný (mix).
    source_label: str | None = None
    playlist_id: str | None = Field(default=None, index=True)
    algorithmic: bool = False
    device_key: str | None = None
    origin: str = "connect"


class ArtistFeedback(SQLModel, table=True):
    """"Víc / míň takových" (plán P2): ruční posun váhy interpreta v mixech a
    Pusť teď. Kladné = víc, záporné = míň; mezi −15 a +15 (jako poslechy)."""

    user_id: str = Field(primary_key=True)
    artist_id: str = Field(primary_key=True)
    delta: float = 0.0
    updated_at: datetime = Field(default_factory=utcnow)


class HomeImpression(SQLModel, table=True):
    """Co Domů profilu ukázalo (mix / playlist v sekci, pozice) -- jednou
    za den a položku. S PlayEvent.playlist_id jde změřit, jestli se mixy
    pouštějí (ukázáno -> přehráno -> dohráno), app/home/impressions.py."""

    user_id: str = Field(primary_key=True)
    day: str = Field(primary_key=True)  # YYYY-MM-DD (Praha)
    item_id: str = Field(primary_key=True)
    section: str | None = None
    position: int = 0


class RecordingDislike(SQLModel, table=True):
    """Zlomené srdce -- skladba, kterou uživatel nechce slyšet (viz
    app/library/dislikes.py)."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    recording_id: str = Field(foreign_key="recording.id", index=True)
    created_at: datetime = Field(default_factory=utcnow)


class SkipStreak(SQLModel, table=True):
    """Kolikrát po sobě profil skladbu přeskočil (přehrání s odehranými
    pár vteřinami a přechodem na jinou skladbu). Dohrání / poslech řádek smaže.
    Od 2 se skladba nebere do mixů a interpret trochu ztratí -- jedno přeskočení
    je jen nálada (viz app/home/personal_mixes.py)."""

    user_id: str = Field(primary_key=True)
    recording_id: str = Field(primary_key=True, foreign_key="recording.id")
    streak: int = 0
    updated_at: datetime = Field(default_factory=utcnow)


class HeardFully(SQLModel, table=True):
    """Skladba, kterou profil aspoň jednou poslechl celou (>= 90 % délky
    skutečně odehráno) -- v appce nenápadná trvalá značka u skladby."""

    user_id: str = Field(primary_key=True)
    recording_id: str = Field(primary_key=True, foreign_key="recording.id")
    first_at: datetime = Field(default_factory=utcnow)


class AppUser(SQLModel, table=True):
    """Profil v appce. Admin (`demo-user` -- všechna dosavadní data) může
    zakládat další profily a přepínat se na ně (viz app/auth.py)."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    name: str
    role: str = "user"  # "admin" | "user"
    created_at: datetime = Field(default_factory=utcnow)
    # Tailscale účet (`Tailscale-User-Login` z `tailscale serve`) -- zařízení
    # bez klíče se podle něj přiřadí k profilu (viz app/auth.py).
    tailscale_login: str | None = Field(default=None, index=True)
    # Vlastní ListenBrainz účet profilu (token z listenbrainz.org/settings).
    # Poslechy profilu jdou JEN s tímhle tokenem -- nikdy s adminovým.
    listenbrainz_token: str | None = Field(default=None, sa_type=EncryptedStr)  # šifrovaně (app/secret_box.py)
    listenbrainz_user: str | None = None
    # Přihlašovací jméno (zakládá admin) a heslo (scrypt). Bez hesla = první
    # přihlášení si ho vytvoří; admin ho při zapomenutí vynuluje.
    username: str | None = Field(default=None, index=True)
    password_hash: str | None = None
    # Žánry, které chce mít profil na Domů jako vlastní řady (id kategorií
    # z app/browse.py), v pořadí výběru.
    home_genres: list[str] | None = Field(default=None, sa_column=Column(JSON))
    # Vzhled profilu (sklo, zrno, motiv) -- klíče `appearance.*` z appky,
    # ať má profil stejný vzhled na každém zařízení.
    appearance: dict | None = Field(default=None, sa_column=Column(JSON))
    # Vlastní Last.fm účet profilu (session klíč z přihlášení na last.fm).
    # Scrobbluje se jen s ním a jen poslechy od připojení -- jiné profily
    # bez vlastního účtu na Last.fm nic neposílají.
    lastfm_session: str | None = Field(default=None, sa_type=EncryptedStr)  # šifrovaně
    lastfm_user: str | None = None
    lastfm_connected_at: datetime | None = None


class AuthToken(SQLModel, table=True):
    """Přihlášení zařízení -- dlouhodobý klíč (v DB jen jeho SHA-256)."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    token_hash: str = Field(index=True, unique=True)
    user_id: str = Field(index=True)
    label: str | None = None
    created_at: datetime = Field(default_factory=utcnow)
    last_used_at: datetime | None = None


class InviteCode(SQLModel, table=True):
    """Jednorázová pozvánka: otevřený odkaz vymění kód za klíč zařízení."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    code_hash: str = Field(index=True, unique=True)
    user_id: str = Field(index=True)
    created_at: datetime = Field(default_factory=utcnow)
    expires_at: datetime
    used_at: datetime | None = None


class PairCode(SQLModel, table=True):
    """Jednorázový kód pro přihlášení NOVÉHO zařízení (k jménu a heslu).
    Vytvoří ho admin pro profil, nebo člověk sám na zařízení, kde už je
    přihlášený; platí krátce a jen jednou. V DB jen SHA-256."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    code_hash: str = Field(index=True, unique=True)
    user_id: str = Field(index=True)
    created_by: str | None = None
    created_at: datetime = Field(default_factory=utcnow)
    expires_at: datetime
    used_at: datetime | None = None


class LibraryEntry(SQLModel, table=True):
    """Skladba v knihovně profilu (ne admina -- ten má všechno stažené).
    Přidá se, když si ji profil pustí, stáhne nebo lajkne; soubor je
    sdílený, odebrání maže jen tenhle řádek."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    recording_id: str = Field(index=True)
    added_at: datetime = Field(default_factory=utcnow)


class PlaylistMember(SQLModel, table=True):
    """Člen společného playlistu -- přidává, odebírá a přeřazuje skladby.
    Vlastník zůstává `Playlist.owner_user_id` (jen on maže a mění obal)."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    playlist_id: str = Field(index=True)
    user_id: str = Field(index=True)
    added_at: datetime = Field(default_factory=utcnow)


class PinnedPlaylist(SQLModel, table=True):
    """Automatický mix (Denní mix, Tvůj mix, žebříček...) připnutý do Knihovny
    "živě" -- dál se přegenerovává, jen je vidět mezi Mými playlisty."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    playlist_id: str = Field(index=True)
    added_at: datetime = Field(default_factory=utcnow)


class ArtistDislike(SQLModel, table=True):
    """Interpret, kterého profil nechce slyšet -- jeho skladby se nedostanou
    do žádného generovaného výběru (mixy, rádia, doporučení, Tvoje výběry),
    viz app/library/dislikes.py."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    artist_id: str = Field(index=True)
    created_at: datetime = Field(default_factory=utcnow)


class FavoriteArtist(SQLModel, table=True):
    """Oblíbený interpret profilu (srdíčko na stránce interpreta) -- filtr
    "Oblíbení" v Knihovně › Interpreti."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    artist_id: str = Field(index=True)
    added_at: datetime = Field(default_factory=utcnow)


class CollectionProgress(SQLModel, table=True):
    """Kde uživatel v albu/playlistu skončil -- sdílené mezi zařízeními
    ("Pokračovat" na mobilu po přehrávání na PC). `route` = stránka alba /
    playlistu v appce; `device_id` = kdo zapsal naposled (jiné zařízení pak
    pozná, že má navázat, ne přepsat)."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_id: str = Field(index=True)
    route: str = Field(index=True)
    recording_id: str
    title: str = ""
    idx: int = 0
    total: int = 0
    position_ms: int = 0
    device_id: str | None = None
    updated_at: datetime = Field(default_factory=utcnow)


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


class Blend(SQLModel, table=True):
    """Společný mix dvou profilů (app/blends.py): `pending` -> `active`
    až po souhlasu pozvaného."""

    id: str = Field(default_factory=new_uuid, primary_key=True)
    user_a: str = Field(index=True)
    user_b: str = Field(index=True)
    created_by: str
    status: str = "pending"  # pending | active
    created_at: datetime = Field(default_factory=utcnow)
    built_at: datetime | None = None
