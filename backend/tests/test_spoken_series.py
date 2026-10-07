"""Řady a pořadí čtení z Wikidat (audioknihy, fáze 3)."""
import asyncio

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.models import SpokenBook, SpokenProgress
from app.spoken import series


def _w(qid, title, number=None, year=None, kinds=()):
    return {"qid": qid, "title": title, "number": number, "year": year, "kinds": set(kinds)}


def test_order_fills_single_gap_by_year_and_drops_short_stories():
    works = [
        _w("Q1", "Poslední přání", 1, 1993), _w("Q2", "Meč osudu", 2, 1992), _w("Q6", "Věž vlaštovky", 6, 1997),
        _w("Q8", "Bouřková sezóna", 8, 2013), _w("Q7", "Paní jezera", None, 1999),
        _w("Q9", "Menší zlo", None, 1990, kinds=[series._SHORT_STORY]), _w("Q10", "Q10"),
        _w("Q11", "Meč osudu", None, 1993),  # jiné vydání téhož dílu
    ]
    parts, loose = series.order_parts(works)
    assert [(p["number"], p["title"]) for p in parts] == [
        (1, "Poslední přání"), (2, "Meč osudu"), (6, "Věž vlaštovky"), (7, "Paní jezera"), (8, "Bouřková sezóna")]
    assert loose == []


def test_gap_with_two_candidates_stays_loose():
    parts, loose = series.order_parts([
        _w("Q1", "A", 1, 2000), _w("Q3", "C", 3, 2010), _w("Qa", "X", None, 2005), _w("Qb", "Y", None, 2006)])
    assert [p["number"] for p in parts] == [1, 3] and [p["title"] for p in loose] == ["X", "Y"]


def test_series_rows_need_author_and_read_ordinal():
    entities = {
        "Q1": {"labels": {"cs": {"value": "Harry Potter a Kámen mudrců"}}, "claims": {
            "P50": [{"mainsnak": {"datavalue": {"value": {"id": "Q34660"}}}}],
            "P179": [{"mainsnak": {"datavalue": {"value": {"id": "Q8337"}}},
                      "qualifiers": {"P1545": [{"datavalue": {"value": "1"}}]}}],
            "P577": [{"mainsnak": {"datavalue": {"value": {"time": "+1997-06-26T00:00:00Z"}}}}],
        }},
        # Film: bez autora -> pryč.
        "Q2": {"labels": {"cs": {"value": "Harry Potter a Kámen mudrců"}}, "claims": {
            "P179": [{"mainsnak": {"datavalue": {"value": {"id": "Q8337"}}},
                      "qualifiers": {"P1545": [{"datavalue": {"value": "1"}}]}}]}},
    }
    rows = series._series_rows(entities, "Q8337")
    assert rows == [{"qid": "Q1", "title": "Harry Potter a Kámen mudrců", "number": 1.0, "year": 1997, "kinds": set()}]


def test_common_prefix_names_series():
    assert series.common_prefix(["Harry Potter a Kámen mudrců", "Harry Potter a Tajemná komnata"]) == "Harry Potter a"[:12]
    assert series.common_prefix(["Barva kouzel", "Mort"]) == ""


def test_with_library_marks_state(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(series, "engine", e)
    with Session(e) as s:
        s.add(SpokenBook(id="b1", source_ref="1", release_title="x", title="Zaklínač I - Poslední přání",
                         author="Andrzej Sapkowski", status="ready", requested_by_user_id="me"))
        s.add(SpokenBook(id="b2", source_ref="2", release_title="x", title="Meč osudu", author="Andrzej Sapkowski",
                         status="ready", requested_by_user_id="me"))
        s.add(SpokenProgress(user_id="me", book_id="b2", file_id="f", position_ms=10, finished=True))
        s.commit()
    data = {"author": "Andrzej Sapkowski", "parts": [
        {"title": "Poslední přání", "number": 1}, {"title": "Meč osudu", "number": 2}, {"title": "Krev elfů", "number": 3}],
        "loose": []}
    out = series.with_library(data, "me")
    assert [(p["bookId"], p["state"]) for p in out["parts"]] == [("b1", "ready"), ("b2", "finished"), (None, None)]


def test_route_hides_series_when_wikidata_fails(monkeypatch):
    import app.routes.spoken as routes

    async def boom(title, author):
        raise RuntimeError("429")

    monkeypatch.setattr(series, "lookup", boom)
    assert asyncio.run(routes.series("Krev elfů", "Sapkowski", current=("me", "x"))) == {"series": None}
