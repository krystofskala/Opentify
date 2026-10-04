"""Opravy z end-to-end testu API (2026-10-04): párování Deezer alb podle typu,
data koncertů, "jiné verze" bez kopií téže skladby, Poslechnout později
podle tracklistu, odebrání oblíbené skladby z knihovny, systémové playlisty."""
from __future__ import annotations

from datetime import datetime, timedelta, timezone

import pytest
from fastapi import HTTPException
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine, select

from app.models import (
    Artist,
    Listen,
    ListenLater,
    MediaAsset,
    MediaAssetStatus,
    Playlist,
    PlaylistItem,
    PlaylistKind,
    Recording,
    Release,
)


@pytest.fixture
def session():
    eng = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(eng)
    with Session(eng) as s:
        yield s


# --- 1. Deezer album vs stejnojmenný singl ---------------------------------


def _bends(session: Session) -> tuple[Artist, Release, Release]:
    artist = Artist(name="Radiohead", mbid="a-rh")
    single = Release(
        artist_id=artist.id, title="The Bends", mbid="rg-single", release_type="single", release_date="1996-07-26",
        external_refs={"tracklistCount": 3, "tracklistTitles": ["planet telex", "my iron lung", "bones"]},
    )
    album = Release(
        artist_id=artist.id, title="The Bends", mbid="rg-album", release_type="album", release_date="1994-11-29",
        external_refs={"tracklistCount": 12, "tracklistTitles": ["planet telex", "the bends", "fake plastic trees", "bones"]},
    )
    session.add_all([artist, single, album])
    session.commit()
    return artist, single, album


def test_deezer_album_goes_to_mb_album_not_single(session):
    from app.catalog.deezer_ingest import ingest_album

    artist, single, album = _bends(session)
    # Singl v DB napřed (dřív vyhrál první stejnojmenný).
    rel = ingest_album(session, {"id": 14880317, "title": "The Bends", "record_type": "album", "nb_tracks": 12}, artist)
    assert rel.id == album.id


def test_deezer_single_does_not_take_mb_album(session):
    from app.catalog.deezer_ingest import ingest_album

    artist, single, album = _bends(session)
    rel = ingest_album(session, {"id": 1, "title": "The Bends", "record_type": "single", "nb_tracks": 3}, artist)
    assert rel.id == single.id
    # Jen MB album -> Deezer singl je jiná deska, nový řádek.
    session.delete(single)
    session.commit()
    rel = ingest_album(session, {"id": 2, "title": "The Bends", "record_type": "single", "nb_tracks": 1}, artist)
    assert rel.id != album.id and rel.release_type == "single"


def test_nested_album_without_type_prefers_album_with_the_track(session):
    from app.catalog.deezer_ingest import ingest_track_with_context

    artist, single, album = _bends(session)
    rec = ingest_track_with_context(session, {
        "id": 138544263, "title": "Fake Plastic Trees", "duration": 290,
        "artist": {"id": 399, "name": "Radiohead"}, "album": {"id": 14880317, "title": "The Bends"},
    })
    assert rec.release_id == album.id


# --- 4. Data koncertů --------------------------------------------------------


@pytest.mark.parametrize(
    ("title", "date", "venue"),
    [
        ("1993-11-08: The Armory, Philadelphia", "1993-11-08", "The Armory, Philadelphia"),
        ("1994‐0x‐xx: Somewhere", "1994", "Somewhere"),
        ("1995‐08‐xx: Club X", "1995-08", "Club X"),
        ("1993‐06–2x: Venue", "1993-06", "Venue"),
        ("2008‐04‐01, evening: Hall", "2008-04-01", "Hall (evening)"),
        ("2008-04-01 (Matinee): Hall", "2008-04-01", "Hall (Matinee)"),
        ("Radiohead 1995‐02‐27: 2 Meter Session", "1995-02-27", "2 Meter Session"),
        ("1989 Live at Y", "1989", "Live at Y"),
        ("2000-12-14 PRE-FM: BBC Radio 1, UK", "2000-12-14", "BBC Radio 1, UK (PRE-FM)"),
        ("2001-06-04: Pinkpop: Megaland", "2001-06-04", "Pinkpop: Megaland"),
        ("OK Computer", None, None),
    ],
)
def test_parse_concert_title(title, date, venue):
    from app.catalog.service import parse_concert_title

    assert parse_concert_title(title, "Radiohead") == (date, venue)


# --- 5. Jiné verze -----------------------------------------------------------


def test_same_song_key_ignores_album_version():
    from app.routes.catalog import same_song_key

    assert same_song_key("33 cigaret") == same_song_key("33 Cigaret (Album Version)")
    assert same_song_key("Ride") != same_song_key("Ride (Live)")


# --- 2. Poslechnout později: album podle tracklistu -----------------------


def test_album_progress_uses_tracklist(session):
    from app.listen_later import _album_progress

    artist = Artist(name="X")
    rel = Release(artist_id=artist.id, title="A")
    recs = [Recording(title=f"T{i}", artist_id=artist.id, release_id=rel.id) for i in range(3)]
    stray = [Recording(title=f"Stray{i}", artist_id=artist.id, release_id=rel.id) for i in range(5)]
    copy = Recording(title="T0", artist_id=artist.id, release_id=rel.id, deezer_id="9")
    rel.external_refs = {"tracklistIds": [r.id for r in recs], "tracklistTitles": ["t0", "t1", "t2"]}
    added = datetime.now(timezone.utc) - timedelta(days=1)
    item = ListenLater(user_id="u", kind="album", target_id=rel.id, added_at=added)
    session.add_all([artist, rel, *recs, *stray, copy, item])
    for r in (recs[0], copy, recs[1], stray[0]):
        session.add(Listen(user_id="u", recording_id=r.id, played_at=datetime.now(timezone.utc)))
    session.commit()
    # 3 skladby tracklistu (ne 9 řádků), T0 dvakrát (kopie) = jednou.
    assert _album_progress(session, "u", item, recs[1]) == (3, 2)


# --- 8./9. Playlisty -----------------------------------------------------------


def _playlist(session: Session, **kw) -> tuple[Playlist, list[Recording]]:
    old = datetime(2020, 1, 1, tzinfo=timezone.utc)
    pl = Playlist(owner_user_id="u", title="P", updated_at=old, **kw)
    recs = [Recording(title=f"T{i}") for i in range(2)]
    session.add_all([pl, *recs])
    session.flush()
    session.add_all([PlaylistItem(playlist_id=pl.id, recording_id=r.id, position=i) for i, r in enumerate(recs)])
    session.commit()
    return pl, recs


def test_reorder_and_remove_bump_updated_at(session):
    from app.routes.playlists import ReorderItemsBody, remove_item, reorder_items

    pl, recs = _playlist(session)
    reorder_items(pl.id, ReorderItemsBody(recording_ids=[recs[1].id, recs[0].id]), session=session, current=("u", "d"))
    session.refresh(pl)
    first = pl.updated_at
    assert first.year > 2020
    pl.updated_at = datetime(2020, 1, 1)
    session.add(pl)
    session.commit()
    remove_item(pl.id, recs[0].id, session=session, current=("u", "d"))
    session.refresh(pl)
    assert pl.updated_at.year > 2020


def test_system_playlists_are_protected(session):
    from app.routes.playlists import AddItemBody, UpdatePlaylistBody, add_item, delete_playlist, update_playlist

    mix, recs = _playlist(session, kind=PlaylistKind.PERSONAL_MIX)
    with pytest.raises(HTTPException) as e:
        add_item(mix.id, AddItemBody(recording_id=recs[0].id), session=session, current=("u", "d"))
    assert e.value.status_code == 403
    liked, _ = _playlist(session, source="liked-songs")
    with pytest.raises(HTTPException):
        delete_playlist(liked.id, session=session, current=("u", "d"))
    with pytest.raises(HTTPException):
        update_playlist(liked.id, UpdatePlaylistBody(title="Jiné"), session=session, current=("u", "d"))
    # Popis se stejným názvem (klient posílá obojí) projde.
    update_playlist(liked.id, UpdatePlaylistBody(title="P", description="moje"), session=session, current=("u", "d"))


# --- 7. Odebrání oblíbené skladby z knihovny -------------------------------


def test_remove_liked_track_unlikes_and_keeps_shared_file(session, tmp_path):
    from app.auth import ADMIN_ID
    from app.routes.library import _remove_for

    rec = Recording(title="T")
    liked = Playlist(owner_user_id=ADMIN_ID, title="Oblíbené", source="liked-songs")
    session.add_all([rec, liked])
    session.flush()
    session.add(PlaylistItem(playlist_id=liked.id, recording_id=rec.id))
    session.add(MediaAsset(recording_id=rec.id, status=MediaAssetStatus.AVAILABLE, storage_path=str(tmp_path / "x.mp3")))
    session.commit()
    out = _remove_for(session, ADMIN_ID, rec.id)
    # Admin lajkoval -> soubor zůstává, lajk je pryč.
    assert out["result"] == "hidden"
    assert session.exec(select(PlaylistItem).where(PlaylistItem.recording_id == rec.id)).first() is None
    assert session.get(MediaAsset, rec.id).status == MediaAssetStatus.AVAILABLE
