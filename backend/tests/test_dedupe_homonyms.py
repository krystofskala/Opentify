"""Úklid duplicit nespojí stejnojmennou cizí kapelu ani sloučený zbytek."""
import uuid

from sqlmodel import Session, select

from app.db import engine
from app.maintenance import dedupe
from app.models import Artist


def test_homonym_and_merged_leftover_are_not_merged_back():
    name = f"Aurora {uuid.uuid4().hex[:6]}"
    with Session(engine) as s:
        keep = Artist(name=name, sort_name=name)
        homonym = Artist(name=name, sort_name=name, external_refs={"homonymOf": "x"})
        leftover = Artist(name=name, sort_name=name, external_refs={"mergedInto": "y"})
        dup = Artist(name=name, sort_name=name)
        s.add_all([keep, homonym, leftover, dup])
        s.commit()
        ids = {keep.id, homonym.id, leftover.id, dup.id}
    dedupe.run(apply=True)
    with Session(engine) as s:
        left = {a.id for a in s.exec(select(Artist).where(Artist.name == name)).all()}
    # Obyčejný duplikát se sloučí, cizí kapela a zbytek zůstanou.
    assert homonym.id in left and leftover.id in left
    assert len(left & {keep.id, dup.id}) == 1 and left <= ids
