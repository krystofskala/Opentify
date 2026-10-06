"""Hlášení z appky přežijí nasazení (soubor), s omezenou velikostí."""

import json

import app.routes.client_log as cl


def test_appends_and_trims(tmp_path, monkeypatch):
    log = tmp_path / "client-log.jsonl"
    monkeypatch.setattr(cl, "LOG_FILE", log)
    monkeypatch.setattr(cl, "MAX_FILE_BYTES", 2000)
    for i in range(100):
        cl._append(json.dumps({"n": i, "pad": "x" * 50}))
    lines = log.read_text(encoding="utf-8").splitlines()
    assert log.stat().st_size <= 2200
    assert json.loads(lines[-1])["n"] == 99
    assert all(json.loads(line) for line in lines)  # žádný useknutý řádek
