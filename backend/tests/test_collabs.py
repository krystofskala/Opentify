"""Rozdělení dotazu na dva interprety (hledání spoluprací)."""
from app.catalog.collabs import splits


def test_split_with_separator():
    assert splits("Béla Fleck & Abigail Washburn") == [("Béla Fleck", "Abigail Washburn")]
    assert splits("Chris Thile a Michael Daves") == [("Chris Thile", "Michael Daves")]


def test_split_without_separator_prefers_balanced():
    out = splits("marc ocoonr tony rice")
    assert out[0] == ("marc ocoonr", "tony rice")
    assert len(out) == 3


def test_single_word_is_not_split():
    assert splits("Radiohead") == []
