"""Sdílené "najdi podle jména, jinak založ" helpery pro zdroje dat bez MBID
(sken lokální hudební knihovny, Spotify import) — na rozdíl od
`app.catalog.upsert` (klíčované MusicBrainz `mbid`) tady žádné mbid k
dispozici není, takže se dedupuje case-insensitive přesnou shodou
jména/názvu. To je vědomé zjednodušení (žádné fuzzy matchování překlepů
nebo variant zápisu) přiměřené osobnímu použití — pokud řádek se stejným
jménem/názvem už existuje (třeba založený dřív přes MusicBrainz search),
znovupoužije se ten, aby lokální soubor/Spotify liked song "přistál" na
stejné nahrávce jako všude jinde v katalogu, ne v paralelní duplicitě.
"""

from __future__ import annotations

from sqlalchemy import func
from sqlmodel import Session, select

from app.models import Artist, Recording, Release


def find_or_create_artist(session: Session, name: str) -> Artist:
    name = name.strip()
    artist = session.exec(select(Artist).where(func.lower(Artist.name) == name.lower())).first()
    if artist is None:
        artist = Artist(name=name, sort_name=name)
        session.add(artist)
        session.commit()
        session.refresh(artist)
    return artist


def find_or_create_release(session: Session, artist: Artist, title: str) -> Release:
    title = title.strip()
    release = session.exec(
        select(Release).where(Release.artist_id == artist.id, func.lower(Release.title) == title.lower())
    ).first()
    if release is None:
        release = Release(artist_id=artist.id, title=title, release_type="album")
        session.add(release)
        session.commit()
        session.refresh(release)
    return release


def find_or_create_recording(
    session: Session,
    artist: Artist,
    title: str,
    *,
    track_number: int | None = None,
    duration_ms: int | None = None,
) -> Recording:
    title = title.strip()
    recording = session.exec(
        select(Recording).where(Recording.artist_id == artist.id, func.lower(Recording.title) == title.lower())
    ).first()
    if recording is None:
        recording = Recording(
            artist_id=artist.id,
            title=title,
            track_number=track_number,
            duration_ms=duration_ms,
        )
        session.add(recording)
        session.commit()
        session.refresh(recording)
    return recording


def attach_release_if_missing(session: Session, recording: Recording, release: Release | None) -> None:
    """Nastaví `release_id`, jen když ho nahrávka ještě nemá — nepřepisuje
    album, které už dřív přišlo z MusicBrainz, lokálním/Spotify tagem."""
    if release is None or recording.release_id is not None:
        return
    recording.release_id = release.id
    session.add(recording)
    session.commit()
