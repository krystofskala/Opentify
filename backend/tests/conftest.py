"""Testy nikdy proti živé databázi: když DATABASE_URL ukazuje na /data/db
(spuštění v kontejneru api), přesměrovat na dočasný soubor. Tabulky se
vytvoří, ať kód s globálním `engine` (routy, generátory) najde schéma i na
čisté databázi v CI."""
from __future__ import annotations

import os
import tempfile

if os.environ.get("DATABASE_URL", "").startswith("sqlite:////data/") or not os.environ.get("DATABASE_URL"):
    # Každý běh na čisté databázi: soubor z minulého běhu (nebo z jiné větve se
    # starším schématem) dával chyby "no column" a kolize pevných ID (18. 10.).
    _db = os.path.join(tempfile.gettempdir(), "opentify-tests.db")
    for _f in (_db, _db + "-wal", _db + "-shm"):
        try:
            os.remove(_f)
        except OSError:
            pass
    os.environ["DATABASE_URL"] = f"sqlite:///{_db}"

from sqlmodel import SQLModel  # noqa: E402

from app.db import engine  # noqa: E402
import app.models  # noqa: E402,F401  -- registrace tabulek

SQLModel.metadata.create_all(engine)
