"""Název a autor knihy z katalogu audioknihy.cz -- jen jistá shoda."""

from app.spoken.metadata import best_match


def work(title, author):
    return {"type": "work", "title": title, "author_name": author}


ITEMS = [
    work("Saturnin", "Zdeněk Jirotka"),
    work("Saturnin se vrací", "Zdeněk Jirotka"),
    work("Saturnin zasahuje", "Miroslav Macek"),
]


def test_exact_title_and_author_surname():
    hit = best_match("Jirotka Zdeněk - Saturnin (2003)(čte Svatopluk Beneš)", ITEMS)
    assert hit["title"] == "Saturnin"


def test_longest_matching_title_wins():
    hit = best_match("Zdenek Jirotka - Saturnin se vraci [2012]", ITEMS)
    assert hit["title"] == "Saturnin se vrací"


def test_author_must_be_in_release():
    # Název sedí, ale autor ne -> radši nic.
    assert best_match("Saturnin zasahuje (čte Někdo)", [work("Saturnin zasahuje", "Jan Novák")]) is None


def test_other_language_edition_is_not_matched():
    items = [work("Zaklínač I Posledné želanie", "Andrzej Sapkowski")]
    assert best_match("Sapkowski Andrzej - Zaklínač I - Poslední přání", items) is None
