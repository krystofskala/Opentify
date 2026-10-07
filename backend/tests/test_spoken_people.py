"""Autor z Wikidat jen při shodě jména, člověk a povolání k roli."""
from app.spoken.people import name_variants, pick


def entity(qid, label, jobs, human=True, aliases=()):
    claim = lambda q: {"mainsnak": {"datavalue": {"value": {"id": q}}}}  # noqa: E731
    return {
        "id": qid,
        "labels": {"cs": {"value": label}},
        "aliases": {"cs": [{"value": a} for a in aliases]},
        "claims": {"P31": [claim("Q5" if human else "Q4167410")], "P106": [claim(j) for j in jobs]},
    }


def test_namesake_footballer_is_skipped_writer_taken():
    footballer = entity("Q1", "Karel Čapek", ["Q937857"])
    writer = entity("Q2", "Karel Čapek", ["Q36180"])
    assert pick([footballer, writer], "Karel Capek", "author")["id"] == "Q2"


def test_other_name_or_non_human_is_skipped():
    assert pick([entity("Q3", "Karel Čapek Jr.", ["Q36180"])], "Karel Čapek", "author") is None
    assert pick([entity("Q4", "Karel Čapek", ["Q36180"], human=False)], "Karel Čapek", "author") is None


def test_narrator_may_be_actor_author_must_write():
    actor = entity("Q5", "Oldřich Vízner", ["Q33999"])
    assert pick([actor], "Oldřich Vízner", "narrator")["id"] == "Q5"
    assert pick([actor], "Oldřich Vízner", "author") is None


def test_surname_first_and_alias():
    assert name_variants("Jirotka, Zdeněk") == {"jirotka, zdenek", "zdenek jirotka"}
    assert pick([entity("Q6", "Z. Jirotka", ["Q36180"], aliases=["Zdeněk Jirotka"])], "Jirotka, Zdeněk", "author")


def test_special_letters_fold():
    assert name_variants("Jo Nesbø") == {"jo nesbo"}
    assert name_variants("Stanisław Lem") == {"stanislaw lem"}
