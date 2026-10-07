"""Popis knihy z Google Books jen při jisté shodě (audit 7. 10.: Zaklínač
našel knihu o počítačové hře)."""
from app.spoken.describe import pick


def vol(title, authors, lang="cs", desc="Popis."):
    return {"volumeInfo": {"title": title, "authors": authors, "language": lang, "description": desc}}


def test_game_book_is_not_the_novel():
    items = [vol("Zaklínač: Svět her", ["Martin Bach"]), vol("Zaklínač", ["Andrzej Sapkowski"], desc="Geralt.")]
    assert pick(items, "Zaklínač", "Andrzej Sapkowski")["description"] == "Geralt."


def test_needs_czech_edition_with_description_and_same_title():
    assert pick([vol("Saturnin", ["Zdeněk Jirotka"], lang="en")], "Saturnin", "Zdeněk Jirotka") is None
    assert pick([vol("Saturnin", ["Zdeněk Jirotka"], desc="")], "Saturnin", "Zdeněk Jirotka") is None
    assert pick([vol("Saturnin se vrací", ["Miroslav Macek"])], "Saturnin", "Zdeněk Jirotka") is None


def test_title_noise_and_surname_first():
    items = [vol("Bylo nás pět", ["Karel Poláček"])]
    assert pick(items, "Bylo nás pět (2010) - čte Jiří Lábus", "Poláček, Karel")
