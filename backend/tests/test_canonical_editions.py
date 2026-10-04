"""Regrese po "kanonické edici" + "jiných edicích" (2026-10-04): staré řádky
se souborem zůstávají v tracklistu, operace nad celým albem jen s jeho
tracklistem, výběr edice, hledání podle jména, souběh vkládání, řazení
hledání, smazání profilu a odesílání do ListenBrainz."""
from __future__ import annotations

import asyncio

import pytest
from sqlalchemy.exc import IntegrityError
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

from app.models import (
    AppUser,
    Artist,
    Blend,
    Listen,
    MediaAsset,
    MediaAssetStatus,
    Playlist,
    PlaylistItem,
    Recording,
    Release,
)


@pytest.fixture
def eng():
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    return e


@pytest.fixture
def session(eng):
    with Session(eng) as s:
        yield s


# --- výběr kanonické edice ----------------------------------------------------


def _ed(status, *track_counts, date="2000"):
    return {
        "status": status,
        "date": date,
        "media": [{"tracks": [{"recording": {"id": f"{status}-{date}-{i}-{n}", "title": f"t{n}"}} for n in range(c)]}
                  for i, c in enumerate(track_counts)],
    }


def test_canonical_edition_skips_empty_and_prefers_official():
    from app.catalog.service import _canonical_edition

    empty = {"status": "Official", "date": "1990", "media": [{"tracks": []}]}
    promo = _ed("Promotion", 10, date="1999")
    official = _ed("Official", 10, 3, date="2001")  # 2 disky, ale oficiální
    assert _canonical_edition([empty, promo, official]) is official
    # Jen bootlegy: funguje dál (nejméně disků, pak datum).
    a, b = _ed("Bootleg", 8, date="1995"), _ed("Bootleg", 8, 8, date="1994")
    assert _canonical_edition([b, a]) is a
    # Jen prázdné edice nespadnou.
    assert _canonical_edition([empty]) is empty


# --- řazení hledání -----------------------------------------------------------


def test_version_words_only_in_brackets_or_after_dash():
    from app.catalog.service import _official_first

    results = [
        {"entityType": "recording", "title": "Live Forever (Live at Knebworth)"},
        {"entityType": "recording", "title": "Live Forever"},
        {"entityType": "recording", "title": "Live Through This"},
        {"entityType": "recording", "title": "Wonderwall - Demo"},
        {"entityType": "recording", "title": "Wonderwall"},
    ]
    titles = [r["title"] for r in _official_first(results, "oasis")]
    assert titles[:3] == ["Live Forever", "Live Through This", "Wonderwall"]
    assert set(titles[3:]) == {"Live Forever (Live at Knebworth)", "Wonderwall - Demo"}


# --- tracklist po změně edice -------------------------------------------------


class _FakeMB:
    def __init__(self, data):
        self.data = data

    async def get_release_group_tracks(self, _mbid):
        return self.data


class _FakeDZ:
    async def find_track_by_isrc(self, _isrc):
        return None


def _album(session):
    artist = Artist(name="Mumford & Sons", mbid="a-mumford")
    release = Release(artist_id=artist.id, title="Sigh No More", mbid="rg-snm", release_type="album")
    session.add_all([artist, release])
    session.commit()
    return artist, release


def _tracks(*items):
    """items: (mbid, title, length_ms)."""
    return {
        "releases": [{
            "status": "Official",
            "date": "2009",
            "media": [{"tracks": [
                {"number": str(i), "recording": {"id": mbid, "title": title, "length": length}}
                for i, (mbid, title, length) in enumerate(items, start=1)
            ]}],
        }]
    }


def _service(session, data):
    from app.catalog.service import CatalogService

    return CatalogService(session, _FakeMB(data), _FakeDZ())


def _old_row(session, release, artist, mbid, title, dur, file_ms=None, track=1):
    rec = Recording(mbid=mbid, release_id=release.id, artist_id=artist.id, title=title, duration_ms=dur,
                    track_number=track, external_refs={"mbDisambiguation": "live, 2010: Shepherds Bush"})
    session.add(rec)
    session.flush()
    session.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, storage_path="/x.mp3",
                           waveform_duration_ms=file_ms))
    session.commit()
    return rec


def test_new_edition_reuses_row_with_file(session):
    artist, release = _album(session)
    # Starý řádek: MBID živé verze z dřívější edice, soubor je ale studiový.
    old = _old_row(session, release, artist, "mb-live", "Sigh No More", 251266, file_ms=208573)
    session.add(Listen(user_id="u", recording_id=old.id))
    session.commit()
    tracks = asyncio.run(_service(session, _tracks(("mb-studio", "Sigh No More", 207893))).get_release_tracks(release.id))
    assert [t.id for t in tracks] == [old.id]
    session.refresh(old)
    assert old.mbid == "mb-studio" and old.duration_ms == 207893
    assert "mbDisambiguation" not in old.external_refs
    rows = session.exec(select(Recording).where(Recording.release_id == release.id)).all()
    assert len(rows) == 1  # žádný nový řádek vedle starého


def test_existing_new_row_is_merged_into_referenced_one(session):
    artist, release = _album(session)
    old = _old_row(session, release, artist, "mb-old", "Timshel", 173000, file_ms=173413)
    # Nový řádek z předchozího načtení (bez souboru, s lajkem).
    new = Recording(mbid="mb-new", release_id=release.id, artist_id=artist.id, title="Timshel", duration_ms=173426)
    pl = Playlist(owner_user_id="u", title="Oblíbené")
    session.add_all([new, pl])
    session.flush()
    session.add(PlaylistItem(playlist_id=pl.id, recording_id=new.id, position=0))
    session.commit()
    new_id = new.id
    tracks = asyncio.run(_service(session, _tracks(("mb-new", "Timshel", 173426))).get_release_tracks(release.id))
    assert [t.id for t in tracks] == [old.id]
    assert session.get(Recording, new_id) is None
    assert session.exec(select(PlaylistItem)).one().recording_id == old.id
    session.refresh(release)
    assert release.external_refs["tracklistIds"] == [old.id]


def test_different_version_is_not_merged(session):
    artist, release = _album(session)
    # Živá verze (soubor 4:11) vs studiová 3:28 -- nic se neslučuje.
    old = _old_row(session, release, artist, "mb-live", "Sigh No More", 251266, file_ms=251266)
    tracks = asyncio.run(_service(session, _tracks(("mb-studio", "Sigh No More", 207893))).get_release_tracks(release.id))
    assert tracks[0].id != old.id
    session.refresh(old)
    assert old.mbid == "mb-live"
    # Clean vs explicit s jinou délkou taky ne.
    rel2 = Release(artist_id=artist.id, title="Monsters", mbid="rg-m", release_type="album")
    session.add(rel2)
    session.commit()
    explicit = _old_row(session, rel2, artist, "mb-x", "Monsters", 222000, file_ms=222000)
    from app.catalog.service import CatalogService

    svc = CatalogService(session, _FakeMB(_tracks(("mb-clean", "Monsters", 212000))), _FakeDZ())
    tracks = asyncio.run(svc.get_release_tracks(rel2.id))
    assert tracks[0].id != explicit.id


def test_row_of_other_album_is_not_merged(session):
    artist, release = _album(session)
    single = Release(artist_id=artist.id, title="Little Lion Man", mbid="rg-single", release_type="single")
    session.add(single)
    session.commit()
    on_single = Recording(mbid="mb-llm", release_id=single.id, artist_id=artist.id, title="Little Lion Man", duration_ms=247000)
    session.add(on_single)
    session.commit()
    old = _old_row(session, release, artist, "mb-llm-live", "Little Lion Man", 255000, file_ms=247100)
    asyncio.run(_service(session, _tracks(("mb-llm", "Little Lion Man", 247000))).get_release_tracks(release.id))
    session.refresh(old)
    assert old.mbid == "mb-llm-live"  # přes alba se neslučuje
    assert session.get(Recording, on_single.id) is not None


# --- album_recordings a operace nad celým albem --------------------------------


def test_album_recordings_uses_tracklist_or_skips_other_editions(session):
    from app.catalog.canonical import album_recordings

    artist, release = _album(session)
    a = Recording(release_id=release.id, artist_id=artist.id, title="A", track_number=2)
    b = Recording(release_id=release.id, artist_id=artist.id, title="B", track_number=1)
    tape = Recording(release_id=release.id, artist_id=artist.id, title="A", external_refs={"otherEdition": "1994 · XE"})
    session.add_all([a, b, tape])
    session.commit()
    assert [r.id for r in album_recordings(session, release)] == [b.id, a.id]
    release.external_refs = {"tracklistIds": [a.id, "smazany", b.id]}
    session.add(release)
    session.commit()
    assert [r.id for r in album_recordings(session, release.id)] == [a.id, b.id]
    assert album_recordings(session, "neni") == []


def test_unfinished_album_counts_only_tracklist(eng, monkeypatch):
    from app.home import extra_sections as xs
    from app.utils import utcnow
    from datetime import timedelta

    with Session(eng) as s:
        artist, release = _album(s)
        recs = [Recording(release_id=release.id, artist_id=artist.id, title=f"t{i}", track_number=i) for i in range(6)]
        tapes = [Recording(release_id=release.id, artist_id=artist.id, title=f"t{i}", external_refs={"otherEdition": "x"})
                 for i in range(30)]
        s.add_all(recs + tapes)
        s.commit()
        rid = release.id
        ids = {r.id for r in recs}
    stats = {rid: {"ctx_last": utcnow() - timedelta(days=2), "ctx_tracks": set(list(ids)[:2]), "tracks": set(list(ids)[:5])}}
    monkeypatch.setattr(xs, "engine", eng)
    monkeypatch.setattr(xs, "_release_stats", lambda _u: stats)
    saved = {}
    monkeypatch.setattr(xs, "_save", lambda _u, key, payload: saved.setdefault(key, payload))
    # 5 ze 6 skladeb tracklistu = dokončeno skoro celé (>= 70 %), nenabízet;
    # dřív se počítalo 36 řádků alba a album se nabízelo.
    assert asyncio.run(xs.build_unfinished("u")) == 0


# --- hledání podle jména -------------------------------------------------------


def test_name_matching_prefers_non_other_edition(session):
    from app.catalog.deezer_ingest import ingest_track
    from app.catalog.top_tracks import _find_local
    from app.library.matching import find_or_create_recording

    artist, release = _album(session)
    tape = Recording(release_id=release.id, artist_id=artist.id, title="The Cave", external_refs={"otherEdition": "live"})
    session.add(tape)
    session.commit()
    studio = Recording(release_id=release.id, artist_id=artist.id, title="The Cave")
    session.add(studio)
    session.commit()
    assert find_or_create_recording(session, artist, "The Cave").id == studio.id
    assert _find_local(session, artist.id, None, "The Cave").id == studio.id
    rec = ingest_track(session, {"id": 99, "title": "The Cave", "duration": 218}, artist=artist, release=None)
    assert rec.id == studio.id
    # Jen řádek z jiné edice -> použije se (nic jiného není).
    only = Recording(artist_id=artist.id, title="Awake My Soul", external_refs={"otherEdition": "live"})
    session.add(only)
    session.commit()
    assert find_or_create_recording(session, artist, "Awake My Soul").id == only.id


# --- souběh vkládání skladeb z jiných edic --------------------------------------


def test_other_editions_insert_skips_concurrent_duplicate(session):
    artist, release = _album(session)
    svc = _service(session, {})
    chosen = {"media": []}
    other = {"date": "2010", "media": [{"tracks": [{"recording": {"id": "mb-dup", "title": "Dust Bowl Dance"}}]}]}
    # Souběžný požadavek už řádek vložil, ale "known" ho ještě neviděl.
    session.add(Recording(mbid="mb-dup", release_id=release.id, artist_id=artist.id, title="Dust Bowl Dance"))
    session.commit()
    real_exec = session.exec
    calls = {"n": 0}

    class _Empty:
        def all(self):
            return []

    def exec_once_empty(stmt, *a, **kw):
        calls["n"] += 1
        return _Empty() if calls["n"] == 1 else real_exec(stmt, *a, **kw)

    session.exec = exec_once_empty  # type: ignore[method-assign]
    svc._ingest_other_editions(release, [chosen, other], chosen)
    session.exec = real_exec  # type: ignore[method-assign]
    assert len(session.exec(select(Recording).where(Recording.mbid == "mb-dup")).all()) == 1


def test_tracklist_get_survives_integrity_error(session):
    artist, release = _album(session)
    rec = Recording(release_id=release.id, artist_id=artist.id, title="A", track_number=1)
    session.add(rec)
    session.commit()
    svc = _service(session, {})

    async def boom(_rid):
        raise IntegrityError("insert", {}, Exception("UNIQUE constraint failed: recording.mbid"))

    svc._get_release_tracks = boom  # type: ignore[method-assign]
    assert [t.id for t in asyncio.run(svc.get_release_tracks(release.id))] == [rec.id]


# --- smazání profilu -------------------------------------------------------------


def test_delete_profile_drops_partner_blends_and_family_rail(eng, monkeypatch):
    from app.library import delete_profile as dp

    monkeypatch.setattr(dp, "engine", eng)
    monkeypatch.setattr(dp, "_delete_redis", lambda _u: 0)
    monkeypatch.setattr(dp, "_delete_covers", lambda _ids: None)
    with Session(eng) as s:
        gone, partner = AppUser(name="Gone"), AppUser(name="Partner")
        s.add_all([gone, partner])
        s.flush()
        blend = Blend(user_a=partner.id, user_b=gone.id, created_by=partner.id, status="active")
        s.add(blend)
        s.flush()
        blend_pl = Playlist(owner_user_id=partner.id, title="Blend", source=f"blend:{blend.id}:blend")
        rail = Playlist(owner_user_id=partner.id, title="Gone poslouchá", source=f"home:rail:family_{gone.id[:8]}")
        own = Playlist(owner_user_id=partner.id, title="Moje")
        s.add_all([blend_pl, rail, own])
        s.commit()
        gone_id, own_id = gone.id, own.id
    dp.delete_profile(gone_id)
    with Session(eng) as s:
        assert [p.id for p in s.exec(select(Playlist)).all()] == [own_id]
        assert s.exec(select(Blend)).all() == []


# --- ListenBrainz: 401 / 429 ------------------------------------------------------


def _pending_listens(eng, n):
    with Session(eng) as s:
        artist = Artist(name="X")
        s.add(artist)
        s.flush()
        rec = Recording(artist_id=artist.id, title="Y")
        s.add(rec)
        s.flush()
        for _ in range(n):
            s.add(Listen(user_id="u", recording_id=rec.id))
        s.commit()


def test_listenbrainz_401_backs_off_and_429_stops_per_entry_loop(eng, monkeypatch):
    from app import listens

    monkeypatch.setattr(listens, "engine", eng)
    monkeypatch.setattr(listens, "_auth_failed", {})
    _pending_listens(eng, 5)
    sent_batches: list[int] = []
    replies = iter([400, 200, 429, 200, 200])

    async def fake_send(entries, _token):
        sent_batches.append(len(entries))
        return next(replies), "x"

    monkeypatch.setattr(listens, "_send", fake_send)
    asyncio.run(listens._submit_for("u", "tok"))
    # Dávka 400 -> po jednom: 200, 429 -> stop (zbytek příště).
    assert sent_batches == [5, 1, 1]

    # 401: profil se 30 min nezkouší (se stejným tokenem).
    async def unauthorized(entries, _token):
        sent_batches.append(len(entries))
        return 401, "HTTP 401"

    monkeypatch.setattr(listens, "_send", unauthorized)
    monkeypatch.setattr(listens, "token_for", lambda _u: "tok")
    sent_batches.clear()
    asyncio.run(listens.submit_pending())
    asyncio.run(listens.submit_pending())
    assert sent_batches == [4]
    # Nový token se zkusí hned.
    monkeypatch.setattr(listens, "token_for", lambda _u: "novy")
    asyncio.run(listens.submit_pending())
    assert sent_batches == [4, 4]


# --- opravný nástroj ---------------------------------------------------------------


def test_repair_tool_merges_new_row_into_referenced_old_one(session):
    from app.tools import repair_canonical_rows as tool

    artist, release = _album(session)
    old = _old_row(session, release, artist, "mb-live", "Winter Winds", 228413, file_ms=219707)
    live = _old_row(session, release, artist, "mb-live2", "Thistle & Weeds", 338720, file_ms=338720)
    new = Recording(mbid="mb-ww", release_id=release.id, artist_id=artist.id, title="Winter Winds", duration_ms=219706, track_number=3)
    tw = Recording(mbid="mb-tw", release_id=release.id, artist_id=artist.id, title="Thistle & Weeds", duration_ms=289866, track_number=9)
    session.add_all([new, tw])
    session.commit()
    release.external_refs = {"tracklistIds": [new.id, tw.id]}
    session.add(release)
    session.commit()
    new_id = new.id
    pairs = tool.plan(session)
    assert [(rec.id, twin.id) for _r, rec, twin in pairs] == [(new_id, old.id)]  # živá verze ne
    tool.apply(session, pairs)
    session.refresh(release)
    session.refresh(old)
    assert release.external_refs["tracklistIds"] == [old.id, tw.id]
    assert old.mbid == "mb-ww" and old.track_number == 3 and old.duration_ms == 219706
    assert session.get(Recording, new_id) is None
    session.refresh(live)
    assert live.mbid == "mb-live2"
