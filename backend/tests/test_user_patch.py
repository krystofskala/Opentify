"""Úprava profilu správcem: prázdné přihlašovací jméno nic nesmaže."""
from __future__ import annotations

import uuid

from sqlmodel import Session

from app.db import engine
from app.models import AppUser
from app.routes.auth import UserPatchIn, update_user


def test_empty_username_keeps_login():
    uid = "patch-" + uuid.uuid4().hex[:8]
    login = "kamos" + uuid.uuid4().hex[:6]
    with Session(engine) as s:
        s.add(AppUser(id=uid, name="Kamoš", role="user", username=login))
        s.commit()
    out = update_user(uid, UserPatchIn(name="Kamarád", username="  "), _admin=None)
    assert out["name"] == "Kamarád"
    with Session(engine) as s:
        assert s.get(AppUser, uid).username == login
    update_user(uid, UserPatchIn(username=login + "x"), _admin=None)
    with Session(engine) as s:
        assert s.get(AppUser, uid).username == login + "x"
