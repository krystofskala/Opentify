"""Dohledání alba z Last.fm na Deezeru: edice, která sedí i verzí."""

from app.browse import _best_edition


def test_studio_over_live_unless_asked() -> None:
    live, remaster, exact = {"title": "Born In The USA (Live)"}, {"title": "Born In The USA (Remastered)"}, {"title": "Born In The U.S.A."}
    assert _best_edition([live, exact], "Born in the U.S.A.") is exact
    assert _best_edition([live, remaster], "Born in the USA") is remaster
    assert _best_edition([{"title": "Alive (Live)"}], "Alive (Live)")["title"] == "Alive (Live)"
    assert _best_edition([], "x") is None
