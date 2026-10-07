"""Nástroje v Obsazení česky i mimo slovník (audit 7. 10.: "bass synthesizer")."""
from __future__ import annotations

import pytest

from app.catalog.credits import _instrument, _label


@pytest.mark.parametrize(
    ("mb", "cz"),
    [
        ("bass synthesizer", "basový syntezátor"),
        ("Moog synthesizer", "syntezátor (Moog)"),
        ("electric twelve-string guitar", "elektrická dvanáctistrunná kytara"),
        ("bass harmonica", "basová foukací harmonika"),
        ("electric piano", "elektrické piano"),
        ("Hammond B-3 organ", "varhany (Hammond B-3)"),
        ("Fender Rhodes", "Rhodes"),
        ("gizmo", "gizmo"),
    ],
)
def test_instrument(mb, cz):
    assert _instrument(mb) == cz


def test_label_uses_fallback():
    assert _label({"type": "instrument", "attributes": ["bass synthesizer", "guest"]}) == (
        "musicians",
        "basový syntezátor (host)",
    )
