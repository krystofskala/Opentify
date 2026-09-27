"""Sdílené upsert helpery Artist/Release/Recording — jediné místo, kde se
externí metadata (MusicBrainz JSON, ListenBrainz JSPF, ...) stávají řádkem
v naší lokální DB. Používá je `CatalogService` (MusicBrainz) i
`RecommendationService` (ListenBrainz), aby obě cesty "do katalogu" psaly
identicky a nevytvářely duplicitní řádky pro stejné `mbid`.
"""

from __future__ import annotations

from sqlmodel import Session, select

from app.models import Artist, Recording, Release
from app.utils import utcnow


def upsert_artist(
    session: Session, *, mbid: str | None, name: str, sort_name: str | None
) -> Artist:
    artist = None
    if mbid:
        artist = session.exec(select(Artist).where(Artist.mbid == mbid)).first()
    if artist is None:
        artist = Artist(mbid=mbid, name=name, sort_name=sort_name or name)
        session.add(artist)
    else:
        artist.name = name
        artist.sort_name = sort_name or artist.sort_name
        artist.updated_at = utcnow()
        session.add(artist)
    session.commit()
    session.refresh(artist)
    return artist


def upsert_release(
    session: Session,
    *,
    mbid: str | None,
    artist_id: str,
    title: str,
    release_date: str | None,
    release_type: str,
) -> Release:
    release = None
    if mbid:
        release = session.exec(select(Release).where(Release.mbid == mbid)).first()
    if release is None:
        release = Release(
            mbid=mbid,
            artist_id=artist_id,
            title=title,
            release_date=release_date,
            release_type=release_type,
        )
        session.add(release)
    else:
        release.title = title
        release.release_date = release_date or release.release_date
        release.release_type = release_type
        release.updated_at = utcnow()
        session.add(release)
    session.commit()
    session.refresh(release)
    return release


def upsert_recording(
    session: Session,
    *,
    mbid: str | None,
    release_id: str | None,
    artist_id: str | None,
    title: str,
    duration_ms: int | None,
    isrc: str | None,
    track_number: int | None,
) -> Recording:
    recording = None
    if mbid:
        recording = session.exec(select(Recording).where(Recording.mbid == mbid)).first()
    if recording is None:
        recording = Recording(
            mbid=mbid,
            release_id=release_id,
            artist_id=artist_id,
            title=title,
            duration_ms=duration_ms,
            isrc=isrc,
            track_number=track_number,
        )
        session.add(recording)
    else:
        recording.title = title
        recording.release_id = release_id or recording.release_id
        recording.artist_id = artist_id or recording.artist_id
        recording.duration_ms = duration_ms or recording.duration_ms
        recording.isrc = isrc or recording.isrc
        recording.track_number = track_number or recording.track_number
        recording.updated_at = utcnow()
        session.add(recording)
    session.commit()
    session.refresh(recording)
    return recording
