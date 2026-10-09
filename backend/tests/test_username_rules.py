"""Přihlašovací jméno: jen písmena / číslice / . _ -, žádné emoji ani
neviditelné znaky, vyhrazená jména a jména z pasti ne, stejně vypadající
jméno je obsazené (8. 10.)."""

import hashlib
import uuid

import pytest
from fastapi import HTTPException
from sqlmodel import Session

from app.db import engine
from app.models import AppUser
from app.routes import auth as a


@pytest.mark.parametrize("name", ["root admin", "👨‍🌾", "Krtek​", "ab", "x" * 33, "abc‮def"])
def test_rejected(name):
    with pytest.raises(HTTPException) as e:
        a._clean_username(name)
    assert e.value.status_code == 400


@pytest.mark.parametrize("name", ["admin", "Root", "ADMÍN", "Opentify"])
def test_reserved(name):
    with pytest.raises(HTTPException):
        a._clean_username(name)


def test_trap_username(monkeypatch):
    monkeypatch.setenv("LOGIN_DENY_SHA256", hashlib.sha256(b"pastnauzivatele").hexdigest())
    with pytest.raises(HTTPException):
        a._clean_username("PastNaUzivatele")


def test_accepted_and_normalized():
    assert a._clean_username("Kryštof_92") == "Kryštof_92"
    assert a._clean_username("Kryštóf") == "Kryštóf"  # rozložené „ó“ -> jeden znak
    assert a._clean_username("misa.k-1") == "misa.k-1"


def test_lookalike_is_taken():
    base = "Look" + uuid.uuid4().hex[:6]
    with Session(engine) as s:
        u = AppUser(name="x", username=base)
        s.add(u)
        s.commit()
        assert a._username_taken(s, base.upper())
        assert a._username_taken(s, base.replace("o", "ó", 1))
        assert not a._username_taken(s, base, except_id=u.id)
