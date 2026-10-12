"""Různorodost Pusť teď (12. 10.): paměť interpretů napříč dny
(app/home/exposure.py) a nastavení objevování profilu."""
from __future__ import annotations

from datetime import timedelta

import pytest
from sqlmodel import Session

from app.db import engine
from app.home import exposure
from app.home import play_now as pn
from app.models import Artist, RecBatchItem, Recording
from app.utils import utcnow


def test_factor_slabne_s_kazdym_nabidnutim_a_ma_dno():
    assert exposure.factor(0) == 1
    assert exposure.factor(1) < exposure.factor(0.5) < 1
    assert exposure.factor(100) == exposure.FLOOR


def test_with_links_oba_smery():
    # Tyler Joseph (sólo) je členem twenty one pilots: nabídnutí jednoho
    # tlumí i druhého, oběma směry.
    links = {"tyler": {"top"}}
    assert exposure.with_links({"top": 2.0}, links)["tyler"] == 2.0
    assert exposure.with_links({"tyler": 1.5}, links)["top"] == 1.5
    assert exposure.with_links({"top": 2.0, "tyler": 3.0}, links) == {"top": 3.0, "tyler": 3.0}


def test_artist_weights_z_nabidnutych_varek_s_polocasem():
    user = "u-exposure-test"
    now = utcnow().replace(tzinfo=None)
    with Session(engine) as s:
        s.add(Artist(id="a-exp-1", name="Exp One"))
        s.add(Artist(id="a-exp-2", name="Exp Two"))
        s.add(Recording(id="r-exp-1", title="One", artist_id="a-exp-1"))
        s.add(Recording(id="r-exp-2", title="Two", artist_id="a-exp-2"))
        s.add(RecBatchItem(batch_id="b1", user_id=user, recording_id="r-exp-1", created_at=now))
        s.add(RecBatchItem(batch_id="b2", user_id=user, recording_id="r-exp-2", created_at=now - timedelta(days=2)))
        # Mimo okno se nepočítá.
        s.add(RecBatchItem(batch_id="b3", user_id=user, recording_id="r-exp-2", created_at=now - timedelta(days=30)))
        s.commit()
    w = exposure.artist_weights(user)
    assert w["a-exp-1"] == pytest.approx(1.0, abs=0.01)
    assert w["a-exp-2"] == pytest.approx(0.5, abs=0.01)  # poločas 2 dny


def test_objevovani_vychozi_ulozeni_a_neznama_uroven():
    user = "u-discovery-test"
    assert pn.discovery_level(user) == pn.DISCOVERY_DEFAULT
    assert pn.DISCOVERY[pn.DISCOVERY_DEFAULT] == pn.NEW_SHARE  # ostatním se nic nemění
    assert pn.set_discovery_level(user, "high") == "high"
    assert pn.discovery_level(user) == "high"
    with pytest.raises(ValueError):
        pn.set_discovery_level(user, "max")
