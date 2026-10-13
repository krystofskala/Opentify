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
