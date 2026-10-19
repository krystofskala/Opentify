"""Spoluautoři v jednom poli se počítají jako známí interpreti (Objevy, 19. 10.:
State Champs přes "Simple Plan & State Champs")."""
from app.catalog.artwork import all_artist_names


def test_all_artist_names_splits_credits() -> None:
    assert all_artist_names("Simple Plan & State Champs") == ["Simple Plan", "State Champs"]
    assert all_artist_names("AURORA;Pomme") == ["AURORA", "Pomme"]
    assert all_artist_names("Alpha feat. Beta") == ["Alpha", "Beta"]
    assert all_artist_names("Rak x Ben") == ["Rak", "Ben"]


def test_all_artist_names_keeps_single_names() -> None:
    assert all_artist_names("The xx") == ["The xx"]
    assert all_artist_names("Karel Gott") == ["Karel Gott"]
