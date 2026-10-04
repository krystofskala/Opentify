"""Testy nikdy proti živé databázi: když DATABASE_URL ukazuje na /data/db
(spuštění v kontejneru api), přesměrovat na dočasný soubor. Tabulky se
vytvoří, ať kód s globálním `engine` (routy, generátory) najde schéma i na
čisté databázi v CI."""
from __future__ import annotations

import os
import tempfile

if os.environ.get("DATABASE_URL", "").startswith("sqlite:////data/") or not os.environ.get("DATABASE_URL"):
    os.environ["DATABASE_URL"] = f"sqlite:///{tempfile.gettempdir()}/opentify-tests.db"

from sqlmodel import SQLModel  # noqa: E402

from app.db import engine  # noqa: E402
import app.models  # noqa: E402,F401  -- registrace tabulek

SQLModel.metadata.create_all(engine)
