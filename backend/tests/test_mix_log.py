"""Měření Denních mixů: záznam po dnech, úklid po 21 dnech, opakování."""

import uuid
from datetime import date, timedelta

from app.home import mix_log


def test_record_prune_and_overlap() -> None:
    user = "ml-" + uuid.uuid4().hex[:8]
    today = date(2026, 10, 7)
    old = (today - timedelta(days=30)).isoformat()
    mix_log.record(user, old, {"1": ["x"]})
    mix_log.record(user, (today - timedelta(days=1)).isoformat(), {"1": ["a", "b", "c", "d"]})
    mix_log.record(user, today.isoformat(), {"1": ["a", "b", "e", "f"]})
    r = mix_log.report(user)
    assert r["dni"] == 2  # 30 dní starý záznam uklizen
    assert r["prumerna_shoda_se_vcerejskem"] == 0.5
