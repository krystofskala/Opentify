from __future__ import annotations

import os

from sqlmodel import Session, SQLModel, create_engine

DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:////data/db/vault.db")

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
# Výchozí pool 5+10 nestačil: async katalogové endpointy drží session po dobu
# čekání na MusicBrainz (1 req/s), takže pár souběžných hledání ho vyčerpalo
# a zasekla se celá appka (živě). Kratší timeout = rychlé selhání místo 30 s.
engine = create_engine(DATABASE_URL, connect_args=connect_args, pool_size=20, max_overflow=20, pool_timeout=10)

# Worker a nástroje čekají na zámek 15 s. API (uvicorn) si to při importu
# app.main sníží podle DB_BUSY_TIMEOUT_MS (docker-compose: 5 s) -- požadavek
# nemá viset za zápisem workeru. Nástroje spuštěné v kontejneru api app.main
# neimportují, takže jim 15 s zůstane.
BUSY_TIMEOUT_MS = 15000


def use_env_busy_timeout() -> None:
    global BUSY_TIMEOUT_MS
    try:
        BUSY_TIMEOUT_MS = max(1000, int(os.environ.get("DB_BUSY_TIMEOUT_MS") or BUSY_TIMEOUT_MS))
    except ValueError:
        pass

if DATABASE_URL.startswith("sqlite"):
    from sqlalchemy import event

    @event.listens_for(engine, "connect")
    def _sqlite_pragmas(dbapi_conn, _record) -> None:  # type: ignore[no-untyped-def]
        # WAL: čtení neblokuje zápis (dřív "database is locked" při souběhu
        # API, workerů a nástrojů na pozadí). busy_timeout: chvíli počkat,
        # místo okamžité chyby. Svazek je ext4 (Docker), WAL je tam bezpečný.
        cur = dbapi_conn.cursor()
        cur.execute("PRAGMA journal_mode=WAL")
        cur.execute(f"PRAGMA busy_timeout={BUSY_TIMEOUT_MS}")
        cur.execute("PRAGMA synchronous=NORMAL")
        cur.close()


def init_db() -> None:
    SQLModel.metadata.create_all(engine)
    _ensure_columns()
    from app.secret_box import encrypt_legacy

    encrypt_legacy(engine)
    _backfill_available_at()


def _backfill_available_at() -> None:
    """`MediaAsset.available_at` pro starší soubory: konec prvního úspěšného
    stažení, jinak (lokální sken) poslední známá změna."""
    from sqlalchemy import text

    with engine.begin() as conn:
        conn.execute(text(
            "UPDATE mediaasset SET available_at = (SELECT min(coalesce(j.finished_at, j.created_at)) "
            "FROM provisioningjob j WHERE j.recording_id = mediaasset.recording_id AND j.status = 'SUCCEEDED') "
            "WHERE available_at IS NULL AND status = 'AVAILABLE'"
        ))
        conn.execute(text("UPDATE mediaasset SET available_at = updated_at WHERE available_at IS NULL AND status = 'AVAILABLE'"))


def _ensure_columns() -> None:
    """`create_all` jen zakládá chybějící TABULKY, ne sloupce navíc na už
    existujících (žádný Alembic v projektu, jen SQLite) -- tenhle jednorázový
    krok při startu doplní sloupce přidané po prvním nasazení (`Artist.country`,
    `Release.genres`), ať appka na starší DB nespadne na "no such column".
    Existující řádky dostanou `NULL` -- volající kód proto všude čte
    `release.genres or []`, ne spoléhá na `default_factory` (ten platí jen
    pro nově vkládané řádky, ne pro načtení staré `NULL` hodnoty).
    """
    migrations: dict[str, list[tuple[str, str]]] = {
        "artist": [("country", "VARCHAR")],
        "release": [("genres", "JSON"), ("deezer_id", "VARCHAR")],
        "mediaasset": [
            ("loudness_gain_db", "FLOAT"),
            ("hidden_from_library", "BOOLEAN"),
            ("waveform", "VARCHAR"),
            ("waveform_duration_ms", "INTEGER"),
            ("available_at", "DATETIME"),
        ],
        "recording": [("deezer_id", "VARCHAR")],
        "listen": [("context", "VARCHAR"), ("lastfm_submitted_at", "DATETIME"), ("lastfm_attempts", "INTEGER")],
        "listenlater": [("source", "VARCHAR")],
        "appuser": [
            ("tailscale_login", "VARCHAR"),
            ("listenbrainz_token", "VARCHAR"),
            ("listenbrainz_user", "VARCHAR"),
            ("username", "VARCHAR"),
            ("password_hash", "VARCHAR"),
            ("home_genres", "JSON"),
            ("appearance", "JSON"),
            ("lastfm_session", "VARCHAR"),
            ("lastfm_user", "VARCHAR"),
            ("lastfm_connected_at", "DATETIME"),
        ],
        "playlistitem": [("added_by", "VARCHAR")],
        "spokenbook": [("source_files", "JSON"), ("language", "VARCHAR"), ("metadata_source", "VARCHAR")],
        "provisioningjob": [("source_provider", "VARCHAR"), ("audio_format", "VARCHAR"), ("interactive", "BOOLEAN")],
        "playlist": [
            ("description", "VARCHAR"),
            ("cover_urls", "JSON"),
            ("section", "VARCHAR"),
            ("expires_at", "DATETIME"),
        ],
    }
    with engine.connect() as conn:
        for table, columns in migrations.items():
            existing = {row[1] for row in conn.exec_driver_sql(f"PRAGMA table_info({table})")}
            for name, sql_type in columns:
                if name not in existing:
                    conn.exec_driver_sql(f"ALTER TABLE {table} ADD COLUMN {name} {sql_type}")
        for index_sql in (
            "CREATE INDEX IF NOT EXISTS ix_release_deezer_id ON release (deezer_id)",
            "CREATE INDEX IF NOT EXISTS ix_recording_deezer_id ON recording (deezer_id)",
            "CREATE INDEX IF NOT EXISTS ix_playlist_section ON playlist (section)",
            # Audit výkonu 2026-10-02 (změřeno na kopii DB):
            # knihovna/hledání v knihovně 2-3 s -> ~30 ms (SQLite bral jen user_id),
            "CREATE INDEX IF NOT EXISTS ix_libraryentry_user_rec ON libraryentry (user_id, recording_id)",
            # "Pokračovat v poslechu" a mixy: 143 ms -> 1 ms,
            "CREATE INDEX IF NOT EXISTS ix_listen_user_played ON listen (user_id, played_at)",
            # porovnání jmen interpretů bez velikosti písmen (každé hledání).
            "CREATE INDEX IF NOT EXISTS ix_artist_lower_name ON artist (lower(name))",
        ):
            conn.exec_driver_sql(index_sql)
        # Statistiky pro plánovač dotazů (nikdy nebyly) -- levné, jen co je potřeba.
        conn.exec_driver_sql("PRAGMA optimize")
        conn.commit()


def get_session():
    with Session(engine) as session:
        yield session
