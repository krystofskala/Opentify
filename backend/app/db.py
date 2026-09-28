from __future__ import annotations

import os

from sqlmodel import Session, SQLModel, create_engine

DATABASE_URL = os.environ.get("DATABASE_URL", "sqlite:////data/db/vault.db")

connect_args = {"check_same_thread": False} if DATABASE_URL.startswith("sqlite") else {}
engine = create_engine(DATABASE_URL, connect_args=connect_args)


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
        "release": [("genres", "JSON")],
        "mediaasset": [("loudness_gain_db", "FLOAT")],
    }
    with engine.connect() as conn:
        for table, columns in migrations.items():
            existing = {row[1] for row in conn.exec_driver_sql(f"PRAGMA table_info({table})")}
            for name, sql_type in columns:
                if name not in existing:
                    conn.exec_driver_sql(f"ALTER TABLE {table} ADD COLUMN {name} {sql_type}")
        conn.commit()


def get_session():
    with Session(engine) as session:
        yield session
