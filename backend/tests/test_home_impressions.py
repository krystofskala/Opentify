"""Co Domů ukázalo se zapíše jednou za den a položku."""
import uuid

from sqlmodel import Session, select

from app.db import engine
from app.home import impressions
from app.models import HomeImpression

_RUN = uuid.uuid4().hex[:8]


def test_records_cards_once_per_day():
    user = "impr-" + _RUN
    home = {"sections": [
        {"id": "quick_picks", "items": [{"id": "mixA"}, {"id": "mixB"}]},
        {"id": "styles", "items": [{"tag": "folk"}]},  # bez id -> nic
        {"id": "mixes", "items": [{"id": "mixA"}]},  # už ukázaný výš
    ]}
    assert impressions.record(user, home) == 2
    assert impressions.record(user, home) == 0
    with Session(engine) as s:
        rows = s.exec(select(HomeImpression).where(HomeImpression.user_id == user)).all()
    assert {(r.item_id, r.section, r.position) for r in rows} == {("mixA", "quick_picks", 0), ("mixB", "quick_picks", 1)}
