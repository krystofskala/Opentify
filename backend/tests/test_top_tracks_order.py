"""Populární jako ve Spotify: podle zobrazeného počtu přehrání (audit 7. 10.)."""
from app.catalog.top_tracks import by_listens


def test_sorted_by_listens_unknown_last_in_source_order():
    items = [
        {"id": "a", "listens": 500},
        {"id": "b", "listens": 2000},
        {"id": "c", "listens": None},
        {"id": "d", "listens": 900},
        {"id": "e"},
    ]
    assert [i["id"] for i in by_listens(items)] == ["b", "d", "a", "c", "e"]
