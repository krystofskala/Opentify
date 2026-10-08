"""Dlouhá kniha z YouTube se převede na MP3 (iPhone ji jako m4a nestihl
načíst, 8. 10.); krátká a MP3 zůstávají, chyba převodu nechá původní."""

import subprocess

from app.spoken import youtube


def test_long_m4a_becomes_mp3(tmp_path, monkeypatch):
    src = tmp_path / "abc.m4a"
    src.write_bytes(b"m4a")
    monkeypatch.setattr(youtube, "_duration_s", lambda _p: 9000.0)

    def fake_run(cmd, **_kw):
        (tmp_path / "abc.mp3.part").write_bytes(b"mp3")
        return subprocess.CompletedProcess(cmd, 0)

    monkeypatch.setattr(subprocess, "run", fake_run)
    out = youtube.to_mp3_if_long(src)
    assert out.name == "abc.mp3" and out.read_bytes() == b"mp3"
    assert not src.exists()


def test_short_and_failed_stay(tmp_path, monkeypatch):
    short = tmp_path / "s.m4a"
    short.write_bytes(b"x")
    monkeypatch.setattr(youtube, "_duration_s", lambda _p: 300.0)
    assert youtube.to_mp3_if_long(short) == short
    mp3 = tmp_path / "a.mp3"
    mp3.write_bytes(b"x")
    assert youtube.to_mp3_if_long(mp3) == mp3

    long = tmp_path / "l.m4a"
    long.write_bytes(b"x")
    monkeypatch.setattr(youtube, "_duration_s", lambda _p: 9000.0)

    def boom(cmd, **_kw):
        raise subprocess.CalledProcessError(1, cmd)

    monkeypatch.setattr(subprocess, "run", boom)
    assert youtube.to_mp3_if_long(long) == long and long.exists()
