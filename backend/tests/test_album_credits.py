"""Obsazení alba z MB vztahů: nástroje česky, role sečtené přes skladby,
asistenti vynechaní, skladatelé přes díla."""
from app.catalog.credits import album_credits


def _rel(kind, name, attrs=(), mbid=None):
    return {"type": kind, "target-type": "artist", "attributes": list(attrs), "artist": {"name": name, "id": mbid or name}}


def test_album_credits():
    release = {
        "relations": [_rel("producer", "John Leckie")],
        "media": [{"tracks": [
            {"id": "t1", "recording": {"relations": [
                _rel("instrument", "Colin", ["bass guitar"]),
                _rel("vocal", "Thom", ["lead vocals"]),
                _rel("engineer", "Asistent", ["assistant"]),
                {"type": "performance", "target-type": "work", "work": {"relations": [_rel("composer", "Thom")]}},
            ]}},
            {"id": "t2", "recording": {"relations": [_rel("instrument", "Colin", ["bass guitar", "guest"])]}},
        ]}],
    }
    out = album_credits(release)
    assert out["tracks"] == 2
    colin = next(p for p in out["musicians"] if p["name"] == "Colin")
    labels = {r["label"]: r["tracks"] for r in colin["roles"]}
    assert labels == {"baskytara": 1, "baskytara (host)": 1}
    assert any(p["name"] == "Thom" and p["roles"][0]["label"] == "zpěv" for p in out["musicians"])
    assert [p["name"] for p in out["writers"]] == ["Thom"]
    prod = {p["name"]: p["roles"][0] for p in out["production"]}
    assert prod == {"John Leckie": {"label": "produkce", "tracks": 2}}  # asistent vynechán
