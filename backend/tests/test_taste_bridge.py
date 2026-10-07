"""Most vkusu: kdo styl opravdu hraje, rodina stylu, nechtěné verze."""

from app.home import taste_bridge as tb


def test_strong_tag_rejects_merged_names() -> None:
    john_smith = [("folk", 100), ("Canadian", 51), ("acoustic", 22), ("rap", 22)]
    eminem = [("rap", 100), ("Hip-Hop", 84)]
    trio = [("indie", 100), ("folk", 60), ("rap", 20)]
    assert not tb.strong(john_smith, "rap")
    assert tb.strong(eminem, "rap")
    assert tb.strong(trio, "rap")  # slabší, ale mezi prvními třemi


def test_family_of_rap_skips_ambiguous_lo_fi() -> None:
    fam = tb.family(["rap"])
    assert "jazz rap" in fam and "czech rap" in fam
    assert "lo-fi" not in fam


def test_aliases_count_as_the_style() -> None:
    names = tb.style_set(["rap"])
    assert {"hip-hop", "hip hop"} <= names
    assert tb.plays_style([("Hip-Hop", 90)], names)
    assert tb.plays_style([("jazz rap", 80)], {"rap"}, ["jazz rap"])
    assert not tb.plays_style([("folk", 100), ("lo-fi", 80)], names, tb.family(["rap"]))


def test_junk_versions() -> None:
    assert tb.is_junk_version("High Enough (Slowed)")
    assert tb.is_junk_version("Song - Sped Up")
    assert not tb.is_junk_version("High Enough")


def test_strong_genre_is_stricter_for_genre_membership() -> None:
    frankie = [("60s", 100), ("classic rock", 83), ("oldies", 55), ("jazz", 50)]
    etta = [("blues", 100), ("soul", 90), ("jazz", 57)]
    assert tb.strong(frankie, "jazz")  # pro styl by prošel
    assert not tb.strong_genre(frankie, "jazz")  # do celého Jazzu ne
    assert tb.strong_genre(etta, "jazz")
