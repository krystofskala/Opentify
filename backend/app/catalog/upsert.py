"""Sdílené upsert helpery Artist/Release/Recording — jediné místo, kde se
externí metadata (MusicBrainz JSON, ListenBrainz JSPF, ...) stávají řádkem
v naší lokální DB. Používá je `CatalogService` (MusicBrainz) i
`RecommendationService` (ListenBrainz), aby obě cesty "do katalogu" psaly
identicky a nevytvářely duplicitní řádky pro stejné `mbid`.
"""

from __future__ import annotations

from sqlalchemy import func
from sqlmodel import Session, select

from app.models import Artist, Recording, Release
from app.utils import utcnow


def upsert_artist(
    session: Session, *, mbid: str | None, name: str, sort_name: str | None, country: str | None = None
) -> Artist:
    artist = None
    if mbid:
        artist = session.exec(select(Artist).where(Artist.mbid == mbid)).first()
    if artist is None:
        # Bez shody podle MBID: stejnojmenný interpret BEZ MBID (z knihovny,
        # Deezeru, Spotify importu) je tentýž -- převezme MBID. Bez tohohle
        # každé volání bez MBID zakládalo nový řádek ("RM, Youjeen" 19x).
        # Interpreti s JINÝM MBID se nepřebírají (různé kapely "Nirvana").
        same_name = [
            a
            for a in session.exec(select(Artist).where(func.lower(Artist.name) == name.strip().lower())).all()
            if not (a.external_refs or {}).get("mergedInto")  # aliasy sloučených duplicit
        ]
        if mbid:
            artist = next((a for a in same_name if a.mbid is None), None)
            if artist is not None:
                artist.mbid = mbid
        else:
            # Bez MBID (soubory z PC): vlastní interpret toho jména má přednost
            # (tátův Kontrast), jinak ten s MBID.
            artist = (
                next((a for a in same_name if (a.mbid or "").startswith("own:")), None)
                or next((a for a in same_name if a.mbid), None)
                or (same_name[0] if same_name else None)
            )
    if artist is None:
        artist = Artist(mbid=mbid, name=name, sort_name=sort_name or name, country=country)
        session.add(artist)
    else:
        artist.name = name
        artist.sort_name = sort_name or artist.sort_name
        # Nepřepisovat `None`-em -- embedded artist-credit stub ze search
        # výsledků `country` typicky vůbec nenese (viz `_ingest_artist_credit`),
        # takže by jinak smazal hodnotu, co už doplnil `_enrich_artist_country`.
        artist.country = country or artist.country
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
    genres: list[str] | None = None,
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
            genres=genres or [],
        )
        session.add(release)
    else:
        release.title = title
        release.release_date = release_date or release.release_date
        release.release_type = release_type
        # Nepřepisovat prázdným seznamem -- volání bez `inc=genres` (většina
        # cest sem) posílá `None`/`[]`, což by jinak smazalo, co už dřív
        # doplnil `_enrich_release_genres`.
        release.genres = genres or release.genres or []
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
    disambiguation: str | None = None,
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
    # Poznámka MusicBrainz k nahrávce ("live, 1994-05-02: ...", "demo",
    # "acoustic") -- verzi, kterou název neříká, pak hlídá stahování
    # (`worker._version_hint`).
    if disambiguation is not None:
        refs = dict(recording.external_refs or {})
        if disambiguation.strip():
            refs["mbDisambiguation"] = disambiguation.strip()
        else:
            refs.pop("mbDisambiguation", None)
        if refs != (recording.external_refs or {}):
            recording.external_refs = refs
            session.add(recording)
    session.commit()
    session.refresh(recording)
    return recording
