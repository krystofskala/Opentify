"""#57: mini alba kompilace -> skutečné album MB podle čísla dílu."""
from app.tools.fix_compilation_fragments import volume_key


def test_volume_key_matches_roman_and_arabic():
    assert volume_key("100% Handmade Music Volume I") == volume_key("Acoustic Disc: 100% Handmade Music, Volume 1")
    assert volume_key("Acoustic Disc:100% Handmade Music, Volume II") == "100 handmade music 2"
    assert volume_key("Handmade Music") is None
