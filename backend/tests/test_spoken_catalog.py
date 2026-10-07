"""Audioknihy jako katalog (fáze 1): rozbor názvu vydání a jisté párování
na knihu z Knihovny.cz. Názvy jsou skutečné ze SkTorrentu (měření 7. 10.)."""
from __future__ import annotations

import pytest

from app.spoken.catalog import match_record, parse_release, work_out


@pytest.mark.parametrize(
    ("title", "parts", "narrator", "minutes"),
    [
        ("Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner", ["Saturnin", "Zdeněk Jirotka"], "Oldřich Vízner", None),
        ("Jirotka Zdeněk - Saturnin (2003)(čte Svatopluk Beneš)", ["Jirotka Zdeněk", "Saturnin"], "Svatopluk Beneš", None),
        ("Foglar Jaroslav - 01 Zahada hlavolamu (David Matasek)2019(8h22m11s)´", ["Foglar Jaroslav", "Zahada hlavolamu"],
         "David Matasek", 502),
        ("Terry Pratchett (UZ16) - Těžké melodično (2023)(CZ)", ["Terry Pratchett", "Těžké melodično"], None, None),
        ("J.R.R.Tolkien / Hobit (2003)", ["J.R.R.Tolkien", "Hobit"], None, None),
        ("Jaroslav Hasek - Osudy dobreho vojaka Svejka 20CD (2017)(CZ)", ["Jaroslav Hasek", "Osudy dobreho vojaka Svejka"],
         None, None),
    ],
)
def test_parse(title, parts, narrator, minutes):
    p = parse_release(title)
    assert p["parts"] == parts
    assert p["narrator"] == narrator
    assert p["durationMin"] == minutes


def test_flags():
    assert parse_release("Zaklinac(Kompletni sbirka Audioknih CZ)")["collection"]
    assert parse_release("Andrzej Sapkowski - serie Zaklinac (2013-2017)(CZ)")["collection"]
    assert not parse_release("Jo Nesbo - Série: Harry Hole 13. - Zatmění (2023)(CZ)")["collection"]
    assert parse_release("Jaroslav Hašek - Osudy dobrého vojáka Švejka 20. CD (2017)(CZ)")["cdPart"]
    assert not parse_release("Jaroslav Hasek - Osudy dobreho vojaka Svejka 20CD (2017)(CZ)")["cdPart"]
    assert parse_release("x - y (2011) zkráceno")["abridged"]


def rec(title, author, formats=("0/BOOKS/",), section=None, secondary=()):
    r = {"id": title, "title": title, "shortTitle": title, "authors": {"primary": {author: []}, "secondary": {s: [] for s in secondary}},
         "formats": list(formats), "publicationDates": ["2022"]}
    if section:
        r["titleSection"] = section
    return r


def test_match_both_orders_and_without_diacritics():
    records = [rec("Saturnin se vrací", "Miroslav Macek, 1944-"), rec("Saturnin", "Zdeněk Jirotka, 1911-2003")]
    assert match_record(parse_release("Saturnin - Zdeněk Jirotka (2010) čte Oldřich Vízner"), records)["title"] == "Saturnin"
    assert match_record(parse_release("Zdenek Jirotka - Saturnin (2007)(CZ)"), records)["title"] == "Saturnin"
    # Pokračování od jiného autora není Saturnin.
    assert match_record(parse_release("Miroslav Macek - Saturnin se vraci (2017)(CZ)"), records)["title"] == "Saturnin se vrací"


def test_series_number_is_not_part_of_the_title():
    records = [rec("Zaklínač. I., Poslední přání", "Andrzej Sapkowski, 1948-", section="I., Poslední přání /")]
    hit = match_record(parse_release("Andrzej Sapkowski - Zaklinac I. Posledni prani (2014)(CZ)"), records)
    assert hit is not None
    work = work_out(hit)
    assert work["title"] == "Poslední přání" and work["series"] == {"name": "Zaklínač", "number": 1}


def test_wrong_author_or_title_is_no_match():
    records = [rec("Zaklínač : vzestup krále všech RPG", "Marcin Kosman"), rec("Zaklínač. II., Meč osudu", "Andrzej Sapkowski")]
    # Antologie / cizí autor se k Sapkowskému nepřiřadí.
    assert match_record(parse_release("Andrzej Sapkowski - Povidky o zaklinaci - Zaklinacsky mec"), records) is None
    assert match_record(parse_release("Neznámý Autor - Poslední přání"), records) is None


def test_audio_record_keeps_narrator_as_contributor():
    records = [rec("Sněhulák", "Jo Nesbø, 1960-", formats=("0/BLIND/", "1/BLIND/AUDIO/"), secondary=("David Matásek, 1963-",))]
    hit = match_record(parse_release("Jo Nesbo - Snehulak (2021 CZ)"), records)
    work = work_out(hit)
    assert work["audio"] and work["contributors"] == ["David Matásek"]
