"""Obal alba: souběžné dotazy na totéž album = jedno hledání; po hledání
před chvílí se cizích služeb znovu neptá (8. 10.: ~480 dotazů za 2 min)."""

import asyncio
import uuid
from datetime import timedelta

from sqlmodel import Session

from app.catalog import artwork
from app.db import engine
from app.models import Artist, Release


def _release() -> str:
    with Session(engine) as s:
        a = Artist(name=f"Cover Throttle {uuid.uuid4().hex[:6]}")
        s.add(a)
        s.flush()
        r = Release(artist_id=a.id, title="Bez obalu", mbid=str(uuid.uuid4()))
        s.add(r)
        s.commit()
        return r.id


def test_concurrent_and_repeated_cover_lookups_hit_services_once(monkeypatch):
    calls = 0

    async def slow_resolve(*_a, **_k):
        nonlocal calls
        calls += 1
        await asyncio.sleep(0.05)
        return None

    monkeypatch.setattr(artwork, "resolve_release_cover", slow_resolve)
    monkeypatch.setattr(artwork, "extract_release_art", lambda _rid: None)
    rid = _release()

    async def burst():
        return await asyncio.gather(*[artwork.fill_release(rid, force=True, min_gap=timedelta(hours=1)) for _ in range(20)])

    assert asyncio.run(burst()) == [False] * 20
    assert calls == 1
    # Hned znovu (další zobrazení dlaždice): bez dotazu ven.
    asyncio.run(artwork.fill_release(rid, force=True, min_gap=timedelta(hours=1)))
    assert calls == 1
    # Nahlášený špatný obal hledá vždy znovu (bez min_gap).
    asyncio.run(artwork.fill_release(rid, force=True))
    assert calls == 2
