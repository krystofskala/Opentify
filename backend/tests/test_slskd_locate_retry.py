"""slskd hlásí dokončený přenos o chvilku dřív, než soubor přesune -- dohledání čeká."""
import asyncio
from pathlib import Path

import app.providers as providers
from app.providers import SlskdProvider


def test_locate_waits_until_file_appears(monkeypatch):
    monkeypatch.setattr(providers, "_LOCATE_RETRY_S", 0)
    calls = {"n": 0}
    found = Path("/data/slskd-downloads/x.flac")

    def fake_locate(self, basename, remote_dir="", since=0.0, size=0):
        calls["n"] += 1
        return found if calls["n"] >= 3 else None

    monkeypatch.setattr(SlskdProvider, "_locate_downloaded_file", fake_locate)
    p = SlskdProvider(base_url="http://slskd")
    assert asyncio.run(p._locate_with_retry("x.flac", "", 0.0, 10)) == found
    assert calls["n"] == 3


def test_locate_gives_up_after_retries(monkeypatch):
    monkeypatch.setattr(providers, "_LOCATE_RETRY_S", 0)
    monkeypatch.setattr(SlskdProvider, "_locate_downloaded_file", lambda *a, **k: None)
    p = SlskdProvider(base_url="http://slskd")
    assert asyncio.run(p._locate_with_retry("x.flac", "", 0.0, 10)) is None
