"""Přemapování textových odkazů po sloučení alb a doplnění délek ze souboru
-- na DB v paměti (živé DB se nedotkne)."""
from __future__ import annotations

from datetime import timedelta

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

from app.maintenance import dedupe
from app.models import (
    Artist,
    CollectionProgress,
    HomeSnapshot,
    Listen,
    MediaAsset,
    MediaAssetStatus,
    Recording,
    Release,
)
from app.tools import fill_durations_from_waveform, remap_merged_ids
from app.utils import utcnow


@pytest.fixture()
def session():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        yield s


def _album(session: Session, title: str, tracks: list[str]) -> tuple[Release, list[Recording]]:
    artist = session.exec(select(Artist)).first() or Artist(name="Opeth")
    session.add(artist)
    session.flush()
    rel = Release(artist_id=artist.id, title=title)
    session.add(rel)
    session.flush()
    recs = [Recording(title=t, release_id=rel.id, artist_id=artist.id, track_number=i + 1) for i, t in enumerate(tracks)]
    session.add_all(recs)
    session.flush()
    return rel, recs


def test_merge_release_rewrites_text_refs(session):
    src, src_recs = _album(session, "Damnation", ["Windowpane", "In My Time of Need"])
    dst, dst_recs = _album(session, "Damnation", ["Windowpane"])
    u = "user-1"
    session.add(CollectionProgress(user_id=u, route=f"/releases/{src.id}", recording_id=src_recs[1].id))
    session.add(Listen(user_id=u, recording_id=src_recs[0].id, context=f"/releases/{src.id}"))
    session.add(Listen(user_id=u, recording_id=src_recs[0].id, context="/library/liked"))
    session.add(HomeSnapshot(key="xsec:test", payload={"albumIds": [src.id, "jine"], "nested": {"id": src.id}}))
    session.commit()

    dedupe.merge_release(session, src, dst)
    session.commit()

    cp = session.exec(select(CollectionProgress)).one()
    assert cp.route == f"/releases/{dst.id}"
    contexts = sorted(lis.context for lis in session.exec(select(Listen)).all())
    assert contexts == sorted([f"/releases/{dst.id}", "/library/liked"])
    snap = session.get(HomeSnapshot, "xsec:test")
    assert snap.payload == {"albumIds": [dst.id, "jine"], "nested": {"id": dst.id}}


def test_progress_conflict_keeps_newer(session):
    old_rel, old_recs = _album(session, "A", ["x"])
    new_rel, new_recs = _album(session, "B", ["y"])
    now = utcnow()
    session.add(CollectionProgress(user_id="u", route=f"/releases/{old_rel.id}", recording_id=old_recs[0].id, updated_at=now))
    session.add(CollectionProgress(user_id="u", route=f"/releases/{new_rel.id}", recording_id=new_recs[0].id,
                                   updated_at=now - timedelta(days=1)))
    session.commit()
    dedupe.remap_release_refs(session, {old_rel.id: new_rel.id})
    session.commit()
    rows = session.exec(select(CollectionProgress)).all()
    assert len(rows) == 1
    assert rows[0].route == f"/releases/{new_rel.id}" and rows[0].recording_id == old_recs[0].id


def test_find_mapping_uses_current_owner_of_recording(session):
    live, recs = _album(session, "What of Our Nature", ["Kafka", "Snowday"])
    other, other_recs = _album(session, "Jiné", ["z"])
    gone = "ff658709-6464-480a-ab0b-f098e903944a"  # album, které už neexistuje
    unknown = "4d986893-0000-0000-0000-000000000000"
    session.add(CollectionProgress(user_id="u", route=f"/releases/{gone}", recording_id=recs[0].id))
    session.add(Listen(user_id="u", recording_id=recs[1].id, context=f"/releases/{gone}"))
    session.add(Listen(user_id="u", recording_id="neexistuje", context=f"/releases/{unknown}"))
    session.add(Listen(user_id="u", recording_id=other_recs[0].id, context=f"/releases/{other.id}"))  # platný
    session.add(HomeSnapshot(key="xsec:anniversaries:u", payload={"ids": [gone]}))
    session.commit()

    mapping, unresolved = remap_merged_ids.find_mapping(session)
    assert mapping == {gone: live.id}
    assert unresolved == {unknown: 1}

    dedupe.remap_release_refs(session, mapping)
    session.commit()
    assert session.exec(select(CollectionProgress)).one().route == f"/releases/{live.id}"
    assert session.get(HomeSnapshot, "xsec:anniversaries:u").payload == {"ids": [live.id]}
    assert remap_merged_ids.find_mapping(session)[0] == {}


def test_fill_durations_never_overwrites_catalog(session):
    _rel, recs = _album(session, "Album", ["bez délky", "s délkou", "nestažená"])
    recs[1].duration_ms = 200_000
    session.add_all([
        MediaAsset(recording_id=recs[0].id, status=MediaAssetStatus.AVAILABLE, waveform_duration_ms=181_500),
        MediaAsset(recording_id=recs[1].id, status=MediaAssetStatus.AVAILABLE, waveform_duration_ms=190_000),
        MediaAsset(recording_id=recs[2].id, status=MediaAssetStatus.MISSING, waveform_duration_ms=100_000),
    ])
    session.commit()
    changed = fill_durations_from_waveform.fill(session)
    session.commit()
    assert [r.id for r, _ in changed] == [recs[0].id]
    assert session.get(Recording, recs[0].id).duration_ms == 181_500
    assert session.get(Recording, recs[1].id).duration_ms == 200_000
    assert session.get(Recording, recs[2].id).duration_ms is None
