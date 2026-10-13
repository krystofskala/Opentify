"""Datum přidání srdíček (13. 10.): Exportify "Added At" a odhad z historie."""
from __future__ import annotations

from datetime import datetime

from app.library.spotify_import import _csv_added
from app.tools.estimate_like_dates import _isotonic_median


def test_exportify_added_at():
    text = "Track Name,Artist Name(s),Added At\nA,X,2019-03-04T10:00:00Z\nB,Y,\nC,Z,nesmysl\n"
    assert _csv_added(text) == [datetime(2019, 3, 4, 10), None, None]


def test_odhad_neprehodi_poradi_kvuli_jedne_vyjimce():
    fitted = _isotonic_median([1, 2, 100, 3, 4, 5])
    assert fitted == sorted(fitted)
    assert fitted[-1] < 100  # jedna pozdní skladba neposune všechny novější
