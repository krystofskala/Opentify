"""Šifrování citlivých hodnot v databázi (tokeny služeb profilů).

Klíč `OPENTIFY_DATA_KEY` je jen v `.env`, ne v DB -- ukradená databáze nebo
její záloha sama o sobě tokeny neprozradí. Sloupec typu `EncryptedStr` se
šifruje/dešifruje sám při zápisu/čtení přes ORM; staré nešifrované hodnoty
se dají číst a `encrypt_legacy()` je při startu přešifruje."""
from __future__ import annotations

import logging
import os
from functools import lru_cache

from cryptography.fernet import Fernet, InvalidToken
from sqlalchemy import String, text
from sqlalchemy.types import TypeDecorator

logger = logging.getLogger(__name__)

PREFIX = "enc1:"


@lru_cache(maxsize=1)
def _fernet() -> Fernet | None:
    key = os.environ.get("OPENTIFY_DATA_KEY", "").strip()
    if not key:
        logger.warning("OPENTIFY_DATA_KEY chybí -- tokeny služeb se ukládají nešifrovaně")
        return None
    return Fernet(key.encode())


def encrypt(value: str | None) -> str | None:
    f = _fernet()
    if value is None or f is None or value.startswith(PREFIX):
        return value
    return PREFIX + f.encrypt(value.encode()).decode()


def decrypt(value: str | None) -> str | None:
    if value is None or not value.startswith(PREFIX):
        return value  # stará nešifrovaná hodnota
    f = _fernet()
    if f is None:
        logger.error("šifrovaný token, ale OPENTIFY_DATA_KEY chybí")
        return None
    try:
        return f.decrypt(value[len(PREFIX):].encode()).decode()
    except InvalidToken:
        logger.error("token nejde dešifrovat (jiný OPENTIFY_DATA_KEY?)")
        return None


class EncryptedStr(TypeDecorator):
    impl = String
    cache_ok = True

    def process_bind_param(self, value, dialect):  # noqa: ANN001
        return encrypt(value)

    def process_result_value(self, value, dialect):  # noqa: ANN001
        return decrypt(value)


# (tabulka, sloupec) se šifrovanými hodnotami
ENCRYPTED_COLUMNS = [("appuser", "listenbrainz_token"), ("appuser", "lastfm_session")]


def encrypt_legacy(engine) -> None:  # noqa: ANN001
    """Jednorázově zašifrovat hodnoty uložené před zavedením šifrování."""
    if _fernet() is None:
        return
    with engine.begin() as conn:
        for table, col in ENCRYPTED_COLUMNS:
            rows = conn.execute(
                text(f"SELECT id, {col} FROM {table} WHERE {col} IS NOT NULL AND {col} NOT LIKE :p"),
                {"p": PREFIX + "%"},
            ).all()
            for row_id, value in rows:
                conn.execute(text(f"UPDATE {table} SET {col} = :v WHERE id = :id"), {"v": encrypt(value), "id": row_id})
            if rows:
                logger.info("zašifrováno %d hodnot %s.%s", len(rows), table, col)
