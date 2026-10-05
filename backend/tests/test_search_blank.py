"""Hledání jen z mezer vrátí prázdno, ne chybu 502 (nalezeno simulací)."""
from fastapi.testclient import TestClient

from app.auth import get_current_user
from app.main import app


def test_blank_query_returns_empty():
    app.dependency_overrides[get_current_user] = lambda: ("blank-user", "dev")
    try:
        r = TestClient(app).get("/api/v1/catalog/search", params={"q": "   "})
    finally:
        app.dependency_overrides.pop(get_current_user, None)
    assert r.status_code == 200
    assert r.json()["results"] == []
