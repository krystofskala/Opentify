"""Boti z internetu: neexistující cesty z logu webu i z API -> jeden
tichý souhrn za hodinu, jen od pár pokusů."""
from __future__ import annotations

from fastapi.testclient import TestClient

import app.probe_watch as pw


def _reset(monkeypatch):
    monkeypatch.setattr(pw, "_pending", {})
    monkeypatch.setattr(pw, "_offset", None)
    monkeypatch.setattr(pw, "_last_sent", 0.0)


def test_log_lines_after_start_are_counted(tmp_path, monkeypatch):
    _reset(monkeypatch)
    log = tmp_path / "funnel-unknown.log"
    log.write_text("2026-10-07T03:00:00+00:00\t1.1.1.1\tGET\t/old.php\tbot\n", encoding="utf-8")
    pw.read_new_lines(str(log))  # co tam bylo před startem, se nepočítá
    assert pw._pending == {}
    with log.open("a", encoding="utf-8") as f:
        f.write("2026-10-07T03:01:00+00:00\t10.0.0.1, 2.2.2.2\tGET\t/wp-login.php\tbot\n")
        f.write("2026-10-07T03:01:01+00:00\t2.2.2.2\tGET\t/.env\tbot\n")
    pw.read_new_lines(str(log))
    assert pw._pending["2.2.2.2"] == {"/wp-login.php": 1, "/.env": 1}


def test_summary_needs_a_few_hits_and_is_hourly(monkeypatch):
    _reset(monkeypatch)
    sent = []
    import app.notify as notify_mod

    monkeypatch.setattr(notify_mod, "notify", lambda title, msg, **kw: sent.append((title, msg, kw)))
    pw.record("3.3.3.3", "/.env")
    pw.record("3.3.3.3", "/.env")
    assert pw.flush(now=10_000) is False  # 2 pokusy -- ještě nic
    pw.record("4.4.4.4", "/wp-admin")
    assert pw.flush(now=10_000) is True
    assert "3× z 2 IP" in sent[0][1] and "/.env" in sent[0][1]
    assert sent[0][2]["priority"] == 2
    for _ in range(5):
        pw.record("5.5.5.5", "/x.php")
    assert pw.flush(now=10_100) is False  # do hodiny znovu ne
    assert pw.flush(now=10_000 + pw.EVERY_S) is True


def test_api_unknown_path_from_internet_is_recorded(monkeypatch):
    _reset(monkeypatch)
    import app.auth as auth
    from app.main import app

    monkeypatch.setattr(auth, "auth_mode", lambda: "login")
    client = TestClient(app)
    hdr = {"Tailscale-Funnel-Request": "?1", "X-Forwarded-For": "6.6.6.6"}
    assert client.get("/api/v1/phpmyadmin/index.php", headers=hdr).status_code == 404
    assert client.get("/health").status_code == 200  # z tailnetu, existuje
    assert pw._pending == {"6.6.6.6": {"/api/v1/phpmyadmin/index.php": 1}}


def test_flood_is_capped(tmp_path, monkeypatch):
    _reset(monkeypatch)
    monkeypatch.setattr(pw, "MAX_READ_BYTES", 200)
    log = tmp_path / "f.log"
    log.write_text("", encoding="utf-8")
    pw.read_new_lines(str(log))
    with log.open("a", encoding="utf-8") as f:
        for i in range(20):
            f.write(f"t\t9.9.9.9\tGET\t/x{i}.php\tbot\n")
    pw.read_new_lines(str(log))
    first = sum(pw._pending["9.9.9.9"].values())
    assert 0 < first < 20  # jen část za jeden tik, celé řádky
    for _ in range(10):
        pw.read_new_lines(str(log))
    assert sum(pw._pending["9.9.9.9"].values()) == 20
    for i in range(600):
        pw.record(f"1.1.{i}.1", "/a")
    assert len(pw._pending) <= pw.MAX_IPS + 1


def test_benign_crawler_paths_are_not_probes():
    pw._pending.clear()
    pw.record("1.2.3.4", "/robots.txt")
    pw.record("1.2.3.4", "/sitemap.xml?x=1")
    pw.record("1.2.3.4", "/.well-known/security.txt")
    assert not pw._pending
    pw.record("1.2.3.4", "/wp-login.php")
    assert pw._pending
    pw._pending.clear()
