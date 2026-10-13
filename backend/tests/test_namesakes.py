"""Malý jmenovec slavnějšího interpreta (14. 10., Journey)."""
import asyncio

from app.catalog import namesakes
from app.models import Artist


def _with(monkeypatch, candidates):
    async def fake(_name):
        return candidates

    monkeypatch.setattr(namesakes, "deezer_candidates", fake)


def test_neznamy_jmenovec_slavne_kapely(monkeypatch):
    _with(monkeypatch, [{"id": 3381, "name": "Journey", "nb_fan": 663789}, {"id": 285841141, "name": "Journey", "nb_fan": 23}])
    assert asyncio.run(namesakes.is_minor_namesake(Artist(name="Journey", deezer_id="285841141")))
    assert not asyncio.run(namesakes.is_minor_namesake(Artist(name="Journey", deezer_id="3381")))


def test_s_musicbrainz_id_nebo_bez_slavneho_jmenovce_ne(monkeypatch):
    _with(monkeypatch, [{"id": 1, "name": "X", "nb_fan": 900000}, {"id": 2, "name": "X", "nb_fan": 50}])
    assert not asyncio.run(namesakes.is_minor_namesake(Artist(name="X", deezer_id="2", mbid="abc")))
    _with(monkeypatch, [{"id": 1, "name": "X", "nb_fan": 3000}, {"id": 2, "name": "X", "nb_fan": 50}])
    assert not asyncio.run(namesakes.is_minor_namesake(Artist(name="X", deezer_id="2")))


def test_seznam_jmenovcu_podle_deezer_id(monkeypatch):
    import uuid

    from sqlmodel import Session

    from app.db import engine

    run = uuid.uuid4().hex[:6]
    name = "Journey " + run
    with Session(engine) as s:
        band = Artist(name=name, deezer_id="b" + run, mbid="mb" + run)
        small = Artist(name=name, deezer_id="s" + run)
        s.add_all([band, small])
        s.commit()
        _with(monkeypatch, [{"id": "b" + run, "name": name, "nb_fan": 663789}, {"id": "s" + run, "name": name, "nb_fan": 23}])
        from_small = asyncio.run(namesakes.namesakes(s, small))
        from_band = asyncio.run(namesakes.namesakes(s, band))
        assert [(a["id"], a["fans"]) for a in from_small] == [(band.id, 663789)]
        assert [(a["id"], a["fans"]) for a in from_band] == [(small.id, 23)]
