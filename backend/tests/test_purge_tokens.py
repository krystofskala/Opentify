"""Nepoužívané klíče zařízení se mažou (nikdy nepoužitý > 1 den, nečinný > 90 dní)."""
from datetime import timedelta

from sqlmodel import Session, select

from app.auth import purge_stale_tokens
from app.db import engine
from app.models import AuthToken
from app.utils import utcnow


def test_purge_stale_tokens():
    now = utcnow()
    with Session(engine) as s:
        rows = [
            AuthToken(token_hash="p-never-old", user_id="u", created_at=now - timedelta(days=3)),
            AuthToken(token_hash="p-never-new", user_id="u", created_at=now - timedelta(hours=2)),
            AuthToken(token_hash="p-used", user_id="u", created_at=now - timedelta(days=30), last_used_at=now - timedelta(days=1)),
            AuthToken(token_hash="p-idle", user_id="u", created_at=now - timedelta(days=200), last_used_at=now - timedelta(days=120)),
        ]
        s.add_all(rows)
        s.commit()
    purge_stale_tokens()
    with Session(engine) as s:
        left = {t.token_hash for t in s.exec(select(AuthToken).where(AuthToken.token_hash.like("p-%"))).all()}
        for t in s.exec(select(AuthToken).where(AuthToken.token_hash.like("p-%"))).all():
            s.delete(t)
        s.commit()
    assert left == {"p-never-new", "p-used"}
