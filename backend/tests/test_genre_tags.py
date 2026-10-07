"""Štítek, který je celým žánrem (jazz), vede na stránku žánru; u stylů
"Patří pod" jen žánry, ne nálady (jazz byl pod "Ráno")."""

import asyncio

from app import tags


def test_genre_tags_map_to_genre_pages() -> None:
    assert tags.genre_for_tag("Jazz") == "jazz"
    assert tags.genre_for_tag("hip-hop") == "hiphop"
    assert tags.genre_for_tag("rap") is None  # užší styl, vlastní stránka
    assert tags.genre_for_tag("bebop") is None
    page = asyncio.run(tags.tag_page("jazz"))
    assert page["genreId"] == "jazz"


def test_style_parents_are_genres_only() -> None:
    # "bossa nova" je v SUBGENRES u nálad (chill, romance, morning) i žánrů
    # (latin, brazil) -- "Patří pod" mají být jen žánry.
    parents = [p for p in tags.parent_genres("bossa nova")]
    assert "morning" in parents and "brazil" in parents
    from app import browse

    genre_parents = [p for p in parents if browse.get_category(p).group == "genre"]
    assert set(genre_parents) == {"latin", "brazil"}
