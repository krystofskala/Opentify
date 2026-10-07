"""Novinky žánru: archivní živáky vydané letos nejsou novinka (audit 7. 10.:
Jazz s Ellou Fitzgerald 1966), album pojmenované po roce ano."""
from __future__ import annotations

import pytest

from app.browse import _archival


@pytest.mark.parametrize(
    "title",
    [
        "Live at Falkoner Theatre, Copenhagen, 6th February 1966 (Live)",
        "Chet in Iceland (Live in Reykjavik 1985)",
        "Estate (Live At The Moonlight November 24,1985)",
        "The Lost Sessions 1972",
    ],
)
def test_archival(title):
    assert _archival(title)


@pytest.mark.parametrize("title", ["1989 (Taylor's Version)", "Impressions", "Blink-182", None, "Live"])
def test_not_archival(title):
    assert not _archival(title)


def test_recent_live_is_new(monkeypatch):
    from datetime import date

    assert not _archival(f"Live in Prague {date.today().year - 1}")
