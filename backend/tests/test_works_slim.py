"""Wikidata entity v cache jen s tím, co čteme -- a pořád se z nich dá
poskládat dílo (druh, rok, skladatel, série, Steam)."""
from app import works


def test_slim_keeps_only_used_props():
    raw = {
        "entities": {
            "Q1": {
                "id": "Q1",
                "labels": {"en": {"value": "Halo"}},
                "sitelinks": {"enwiki": {"title": "Halo (video game)"}},
                "claims": {
                    "P31": [{"mainsnak": {"datavalue": {"value": {"id": "Q7889"}}}, "references": ["x" * 1000]}],
                    "P577": [{"mainsnak": {"datavalue": {"value": {"time": "+2001-11-15T00:00:00Z"}}}}],
                    "P1733": [{"mainsnak": {"datavalue": {"value": "976730"}}}],
                    "P2002": [{"mainsnak": {"datavalue": {"value": "nepotřebné"}}}],
                },
            }
        }
    }
    slim = works._slim(raw)["entities"]["Q1"]
    assert set(slim["claims"]) == {"P31", "P577", "P1733"}
    assert "references" not in slim["claims"]["P31"][0]
    assert works.kind_of(slim) == "game"
    assert works._year(slim) == 2001
    assert works._label(slim) == "Halo"
