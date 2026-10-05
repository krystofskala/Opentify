"""Alba, která Deezer nemá (Acoustic Disc "100% Handmade Music"), doplní
hledání z MusicBrainz -- jen shodná se všemi slovy dotazu, a jen když Deezer
nemá aspoň 3 shodná alba."""
import asyncio
import uuid

from sqlmodel import Session

from app.catalog.service import CatalogService
from app.db import engine


class _FakeMB:
    def __init__(self, groups):
        self.groups = groups
        self.calls = 0

    async def search(self, entity, query, limit, offset):
        self.calls += 1
        return {"release-groups": self.groups}


def _rg(title, score=99):
    return {
        "id": str(uuid.uuid4()),
        "title": title,
        "score": score,
        "primary-type": "Album",
        "artist-credit": [{"name": "Various Artists", "artist": {"id": str(uuid.uuid4()), "name": "Various Artists"}}],
    }


def test_adds_matching_musicbrainz_albums():
    run = uuid.uuid4().hex[:6]
    mb = _FakeMB([_rg(f"Acoustic Disc: 100% Handmade Music {run}, Volume 1"), _rg("Handmade", 52), _rg("Something Else")])
    with Session(engine) as s:
        svc = CatalogService(s, mb, None)  # type: ignore[arg-type]
        deezer = [{"entityType": "release", "id": "x", "title": "Ultimate House Beats"}]
        out = asyncio.run(svc._with_musicbrainz_albums(f"100% handmade music {run}", deezer))
    titles = [r["title"] for r in out]
    assert titles[0].startswith("Acoustic Disc: 100% Handmade Music") and titles[1] == "Ultimate House Beats"
    assert len(out) == 2  # neshodné a málo jisté z MB ne


def test_skips_musicbrainz_when_deezer_has_enough():
    mb = _FakeMB([_rg("OK Computer")])
    with Session(engine) as s:
        svc = CatalogService(s, mb, None)  # type: ignore[arg-type]
        deezer = [{"entityType": "release", "id": str(i), "title": t} for i, t in enumerate(["OK Computer", "OK Computer OKNOTOK", "OK Computer (8-bit)"])]
        out = asyncio.run(svc._with_musicbrainz_albums("ok computer", deezer))
    assert out == deezer and mb.calls == 0
