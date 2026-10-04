"""Smazání profilu maže každou tabulku s osobními daty (sloupec user_id) --
nová tabulka se nesmí zapomenout."""
from sqlmodel import SQLModel

import app.models  # noqa: F401 -- registrace tabulek
from app.library.delete_profile import _PER_USER


def test_every_user_table_is_deleted_with_profile():
    covered = {m.__tablename__ for m in _PER_USER}
    with_user = {name for name, table in SQLModel.metadata.tables.items() if "user_id" in table.columns}
    assert with_user <= covered, f"Smazání profilu zapomíná: {sorted(with_user - covered)}"
