"""Hi-res soubory se streamují jako menší kopie (app/stream_copy.py)."""

import asyncio
import os

from app import stream_copy


def _setup(tmp_path, monkeypatch, convert_ok=True):
    monkeypatch.setattr(stream_copy, "CACHE_DIR", tmp_path / "cache")
    calls = []

    async def fake_convert(original, copy):
        calls.append(original)
        if not convert_ok:
            return False
        copy.parent.mkdir(parents=True, exist_ok=True)
        copy.write_bytes(b"small")
        return True

    monkeypatch.setattr(stream_copy, "_convert", fake_convert)
    original = tmp_path / "a.flac"
    original.write_bytes(b"big")
    return original, calls


def test_small_file_streams_original(tmp_path, monkeypatch):
    original, calls = _setup(tmp_path, monkeypatch)
    assert asyncio.run(stream_copy.path_for_stream("r1", original, 1100)) == original
    assert calls == []


def test_lossy_file_never_converted(tmp_path, monkeypatch):
    _, calls = _setup(tmp_path, monkeypatch)
    mp3 = tmp_path / "a.mp3"
    mp3.write_bytes(b"x")
    assert asyncio.run(stream_copy.path_for_stream("r1", mp3, 5000)) == mp3
    assert calls == []


def test_hires_converted_once_then_cached(tmp_path, monkeypatch):
    original, calls = _setup(tmp_path, monkeypatch)
    first = asyncio.run(stream_copy.path_for_stream("r1", original, 4819))
    second = asyncio.run(stream_copy.path_for_stream("r1", original, 4819))
    assert first == second == tmp_path / "cache" / "r1.flac"
    assert len(calls) == 1


def test_changed_original_reconverts(tmp_path, monkeypatch):
    original, calls = _setup(tmp_path, monkeypatch)
    copy = asyncio.run(stream_copy.path_for_stream("r1", original, 4819))
    old = copy.stat().st_mtime - 100
    os.utime(copy, (old, old))
    asyncio.run(stream_copy.path_for_stream("r1", original, 4819))
    assert len(calls) == 2


def test_failed_conversion_falls_back_to_original(tmp_path, monkeypatch):
    original, _ = _setup(tmp_path, monkeypatch, convert_ok=False)
    assert asyncio.run(stream_copy.path_for_stream("r1", original, 4819)) == original


def test_parallel_requests_convert_once(tmp_path, monkeypatch):
    original, calls = _setup(tmp_path, monkeypatch)

    async def both():
        return await asyncio.gather(
            stream_copy.path_for_stream("r1", original, 4819),
            stream_copy.path_for_stream("r1", original, 4819),
        )

    a, b = asyncio.run(both())
    assert a == b and len(calls) == 1
