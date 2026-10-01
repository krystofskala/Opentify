from __future__ import annotations

import os

from sqlmodel import Session, SQLModel, create_engine

DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:////data/db/vault.db")

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
# Výchozí pool 5+10 nestačil: async katalogové endpointy drží session po dobu
# čekání na MusicBrainz (1 req/s), takže pár souběžných hledání ho vyčerpalo
# a zasekla se celá appka (živě). Kratší timeout = rychlé selhání místo 30 s.
engine = create_engine(DATABASE_URL, connect_args=connect_args, pool_size=20, max_overflow=20, pool_timeout=10)


def init_db() -> None:
    SQLModel.metadata.create_all(engine)
    _ensure_columns()


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
        ],
        "recording": [("deezer_id", "VARCHAR")],
        "listen": [("context", "VARCHAR")],
        "listenlater": [("source", "VARCHAR")],
        "appuser": [
            ("tailscale_login", "VARCHAR"),
            ("listenbrainz_token", "VARCHAR"),
            ("listenbrainz_user", "VARCHAR"),
            ("username", "VARCHAR"),
            ("password_hash", "VARCHAR"),
            ("home_genres", "JSON"),
            ("appearance", "JSON"),
        ],
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
        ):
            conn.exec_driver_sql(index_sql)
        conn.commit()


def get_session():
    with Session(engine) as session:
        yield session
