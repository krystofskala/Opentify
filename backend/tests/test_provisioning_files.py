"""Soubory ve stahovací pipeline (review 2026-10-04): kolize jmen mezi
upgradem a novým jobem, přepis přehrávaného souboru, vyčerpané pokusy,
samooprava chybějícího souboru, přísnější shoda otisku."""
from __future__ import annotations

import asyncio
import json

import pytest
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.models import MediaAsset, MediaAssetStatus, ProvisioningJob, ProvisioningJobStatus, Recording


@pytest.fixture()
def eng(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    from app import provisioning_service, worker
    from app.library import file_tags

    monkeypatch.setattr(worker, "engine", e)
    monkeypatch.setattr(provisioning_service, "engine", e)
    monkeypatch.setattr(file_tags, "engine", e)
    return e


class FakeRedis:
    def __init__(self) -> None:
        self.z: dict[str, float] = {}
        self.keys: set[str] = set()

    async def zrangebyscore(self, _key, lo, hi, start=0, num=None):
        return [m for m, s in sorted(self.z.items(), key=lambda kv: kv[1]) if lo <= s <= hi][:num]

    async def zrange(self, _key, _a, _b):
        return list(self.z)

    async def zrem(self, _key, item):
        return 1 if self.z.pop(item, None) is not None else 0

    async def zadd(self, _key, mapping):
        self.z.update(mapping)

    async def exists(self, key):
        return 1 if key in self.keys else 0


def _rec(session: Session, **refs) -> Recording:
    rec = Recording(title="Song", duration_ms=200_000, external_refs=refs)
    session.add(rec)
    session.commit()
    session.refresh(rec)
    return rec


# --- 1: přesun nikdy nepřepíše cizí soubor ---------------------------------


def test_place_file_never_overwrites(tmp_path):
    from app.providers import place_file

    live = tmp_path / "media" / "rid.flac"
    live.parent.mkdir()
    live.write_bytes(b"LIVE")
    src = tmp_path / "dl.flac"
    src.write_bytes(b"NEW")
    out = place_file(src, live)
    assert out != live and out.name == "rid_1.flac"
    assert live.read_bytes() == b"LIVE" and out.read_bytes() == b"NEW"
    assert not src.exists()
    assert not list(live.parent.glob(".*.part"))


def test_fresh_stems_unique(tmp_path, monkeypatch):
    from app import worker

    monkeypatch.setattr(worker, "MEDIA_ROOT", tmp_path)
    stems = {worker._fresh_stem("rid", "yt") for _ in range(50)}
    assert len(stems) == 50
    assert all(s.name.startswith("rid_yt") and s.parent == tmp_path for s in stems)


def test_upgrade_never_touches_live_file(eng, tmp_path):
    """Soubor upgradu je mezitím živý soubor skladby -> nesmí se smazat."""
    from app import worker

    live = tmp_path / "rid.flac"
    live.write_bytes(b"LIVE")
    with Session(eng) as s:
        rec = _rec(s)
        s.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, storage_path=str(live)))
        s.commit()
        rid = rec.id
    r = FakeRedis()
    item = {"recording_id": rid, "new_path": str(live), "replaces": "/x/old_yt.m4a", "source": "slskd", "format": "flac"}
    r.z[json.dumps(item)] = 0
    asyncio.run(worker._process_due_upgrades(r))
    assert live.read_bytes() == b"LIVE"
    assert not r.z


def test_upgrade_postponed_while_streaming(eng, tmp_path):
    from app import worker
    from app.provisioning_service import streaming_key

    old, new = tmp_path / "rid_yt1.m4a", tmp_path / "rid_up1.flac"
    old.write_bytes(b"OLD")
    new.write_bytes(b"NEW")
    with Session(eng) as s:
        rec = _rec(s)
        s.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, storage_path=str(old)))
        s.commit()
        rid = rec.id
    r = FakeRedis()
    r.keys.add(streaming_key(rid))
    r.z[json.dumps({"recording_id": rid, "new_path": str(new), "replaces": str(old), "source": "slskd", "format": "flac"})] = 0
    asyncio.run(worker._process_due_upgrades(r))
    assert old.exists() and new.exists()
    (postponed,) = r.z.values()
    assert postponed > 0  # vrácen do fronty na později


def test_new_job_cancels_pending_upgrades(eng, tmp_path, monkeypatch):
    from app import provisioning_service

    monkeypatch.setattr(provisioning_service, "MEDIA_ROOT", tmp_path)
    up = tmp_path / "rid_up1.flac"
    up.write_bytes(b"UP")
    r = FakeRedis()
    r.z[json.dumps({"recording_id": "rid", "new_path": str(up), "replaces": "x"})] = 10
    r.z[json.dumps({"recording_id": "other", "new_path": str(tmp_path / "o.flac"), "replaces": "y"})] = 10
    assert asyncio.run(provisioning_service.cancel_upgrades(r, "rid")) == 1
    assert not up.exists()
    assert len(r.z) == 1


# --- 6, 7: zamítnuté otisky do upgradu, nový soubor = nové tagy ---------------


def test_target_from_db_carries_rejected_fingerprints(eng):
    from app import worker

    with Session(eng) as s:
        rid = _rec(s, rejectedFingerprints=["AAAA", "BBBB"]).id
    target = worker._target_from_db(rid, "slskd")
    assert target.rejected_fps == ("AAAA", "BBBB")


def test_apply_upgrade_forgets_tags(eng, tmp_path):
    from app import worker

    old, new = tmp_path / "a_yt.m4a", tmp_path / "a.flac"
    old.write_bytes(b"OLD")
    new.write_bytes(b"NEW")
    with Session(eng) as s:
        rec = _rec(s, tagsData="abc", tagsLyrics=True)
        s.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, storage_path=str(old)))
        s.commit()
        rid = rec.id
    assert worker._apply_upgrade(rid, str(new), str(old), "slskd", "flac", None, "slskd:u|f")
    with Session(eng) as s:
        refs = s.get(Recording, rid).external_refs
    assert "tagsData" not in refs and refs["sourceKey"] == "slskd:u|f"
    assert not old.exists()


def test_finish_success_forgets_tags(eng, tmp_path):
    from app import worker

    with Session(eng) as s:
        rec = _rec(s, tagsData="abc")
        s.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.DOWNLOADING))
        job = ProvisioningJob(recording_id=rec.id, requested_by_user_id="u", status=ProvisioningJobStatus.RUNNING)
        s.add(job)
        s.commit()
        rid, jid = rec.id, job.id
    assert worker._finish_success(jid, str(tmp_path / "x.flac"), "sum", 3, "slskd", "flac", None)
    with Session(eng) as s:
        assert "tagsData" not in s.get(Recording, rid).external_refs


# --- 9: vyčerpané pokusy, deterministické "nemáme" ----------------------------


def test_start_job_fails_exhausted_job(eng):
    from app import worker

    with Session(eng) as s:
        rec = _rec(s)
        s.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.DOWNLOADING))
        job = ProvisioningJob(
            recording_id=rec.id, requested_by_user_id="u", status=ProvisioningJobStatus.RUNNING, attempts=3, max_attempts=3
        )
        s.add(job)
        s.commit()
        rid, jid = rec.id, job.id
    ctx = worker._start_job(jid)
    assert ctx["skip"] and ctx["exhausted"]
    with Session(eng) as s:
        assert s.get(ProvisioningJob, jid).status == ProvisioningJobStatus.FAILED
        assert s.get(ProvisioningJob, jid).attempts == 3
        assert s.get(MediaAsset, rid).status == MediaAssetStatus.FAILED


@pytest.mark.parametrize(
    "msg,missing",
    [
        ("slskd: žádný vhodný soubor; youtube: YouTube nemá 'X' v téhle verzi ({})", True),
        ("slskd: žádný vhodný soubor; youtube: youtube: prázdný dotaz", True),
        ("slskd: x; youtube: YouTube: žádný další kandidát pro 'X'", True),
        ("Nemáme tuhle verzi: žádný zdroj neprošel kontrolou", True),
        ("slskd: žádný peer soubor nedodal; youtube: HTTP Error 403", False),
        ("obstarání nedoběhlo do 2400 s -- přerušeno", False),
    ],
)
def test_missing_version_detection(msg, missing):
    from app import worker

    assert worker._is_missing_version(msg) is missing


# --- 5: samooprava chybějícího souboru ---------------------------------------


def test_missing_file_self_heals(eng, tmp_path, monkeypatch):
    from app import provisioning_service

    monkeypatch.setattr(provisioning_service, "MEDIA_ROOT", tmp_path)
    (tmp_path / "_zalohy").mkdir()  # disk připojený
    with Session(eng) as s:
        rec = _rec(s)
        s.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, storage_path=str(tmp_path / "gone.flac")))
        s.commit()
        asset, job, created = provisioning_service.get_or_create_job(s, rec.id, "u", None)
        assert created and job is not None
        assert asset.status == MediaAssetStatus.QUEUED and asset.storage_path is None


def test_unplugged_media_disk_does_not_mark_missing(eng, tmp_path, monkeypatch):
    from app import provisioning_service

    # Prázdný bind mount: složka existuje, disk ne.
    monkeypatch.setattr(provisioning_service, "MEDIA_ROOT", tmp_path)
    with Session(eng) as s:
        rec = _rec(s)
        s.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, storage_path=str(tmp_path / "gone.flac")))
        s.commit()
        asset, job, _created = provisioning_service.get_or_create_job(s, rec.id, "u", None)
        assert job is None and asset.status == MediaAssetStatus.AVAILABLE


def test_own_music_outside_media_root_is_not_redownloaded(eng, tmp_path, monkeypatch):
    from app import provisioning_service

    monkeypatch.setattr(provisioning_service, "MEDIA_ROOT", tmp_path / "media")
    (tmp_path / "media").mkdir()
    with Session(eng) as s:
        rec = _rec(s)
        s.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, storage_path="/data/local-music/a.flac"))
        s.commit()
        _asset, job, _created = provisioning_service.get_or_create_job(s, rec.id, "u", None)
        assert job is None


# --- 8: tagy nevzkřísí smazaný / nahrazený soubor -----------------------------


def test_tag_write_does_not_resurrect_replaced_file(tmp_path, monkeypatch):
    from app.library import file_tags

    path = tmp_path / "a.mp3"
    path.write_bytes(b"ID3")
    monkeypatch.setitem(file_tags._WRITERS, ".mp3", lambda p, *_a: p.write_bytes(b"TAGGED"))
    monkeypatch.setattr(file_tags, "_picture", lambda _d: None)
    assert file_tags.write(path, {}, None, lambda: False) is False
    assert path.read_bytes() == b"ID3"

    def gone() -> bool:
        path.unlink()
        return True

    assert file_tags.write(path, {}, None, gone) is False
    assert not path.exists()
    path2 = tmp_path / "b.mp3"
    path2.write_bytes(b"ID3")
    assert file_tags.write(path2, {}, None, lambda: True) is True
    assert path2.read_bytes() == b"TAGGED"
    assert not list(tmp_path.glob(".*.tagging"))


def test_tag_write_skips_deleted_file(tmp_path, monkeypatch):
    from app.library import file_tags

    path = tmp_path / "a.mp3"
    path.write_bytes(b"ID3")

    def writer(p, *_a):
        p.write_bytes(b"TAGGED")
        path.unlink()  # mezitím smazáno ("Špatná verze")

    monkeypatch.setitem(file_tags._WRITERS, ".mp3", writer)
    monkeypatch.setattr(file_tags, "_picture", lambda _d: None)
    assert file_tags.write(path, {}, None) is False
    assert not path.exists()


# --- 3: shoda otisku musí sedět i délkou --------------------------------------


def _target(**kw):
    from app.library.verify_file import Target

    return Target(recording_id="r", title="Song", artist="A", **{"album": None, "expected_ms": None, **kw})


def test_fingerprint_match_needs_matching_cut():
    from app.library.verify_file import _cut_fits

    # Důvěryhodná ukázka (Deezer = katalog 240 s), soubor je radio edit 200 s.
    assert not _cut_fits(_target(expected_ms=240_000), 240.0, 240_000, 200.0, True, None)
    assert _cut_fits(_target(expected_ms=240_000), 240.0, 240_000, 241.0, True, None)
    # Nedůvěryhodná ukázka (Deezer 200 s = edit), katalog 240 s, soubor 200 s.
    assert not _cut_fits(_target(expected_ms=240_000, album="Album"), 240.0, 200_000, 200.0, False, "Other Single")
    # Katalog má špatnou délku, ukázka je z téhož alba a sedí na soubor (živě).
    assert _cut_fits(_target(expected_ms=300_000, album="Album"), 300.0, 200_000, 201.0, False, "Album")
    # Nedůvěryhodná ukázka, ale soubor sedí na katalog.
    assert _cut_fits(_target(expected_ms=240_000), 240.0, 200_000, 239.0, False, None)
    # Katalog délku nezná -> platí délka ukázky.
    assert _cut_fits(_target(), None, 200_000, 202.0, False, None)
    assert not _cut_fits(_target(), None, 200_000, 260.0, False, None)
