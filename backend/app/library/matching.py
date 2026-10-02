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

import unicodedata

from sqlalchemy import func
from sqlmodel import Session, select

from app.models import Artist, Recording, Release


def primary_of(name: str) -> str:
    """Hlavní interpret z víc-hodnotového tagu -- "Danny Vera;The Rosenberg
    Trio" (tagy souborů spojují víc interpretů středníkem) -> "Danny Vera".
    Jinak vznikal druhý interpret a s ním i druhá kopie skladby/alba."""
    return name.split(";")[0].strip() or name.strip()


def _nfc(text: str) -> str:
    return unicodedata.normalize("NFC", text)


def find_or_create_artist(session: Session, name: str) -> Artist:
    name = _nfc(primary_of(name))
    # Nejdřív přesná shoda: SQLite `lower()` mění jen ASCII -- "Mňága a Žďorp"
    # se přes něj nikdy nenašel a každá skladba dostala nového interpreta
    # (a s ním vlastní album).
    def best(rows: list[Artist]) -> Artist | None:
        # Sloučené duplicity (`mergedInto`) a stejnojmenné cizí kapely
        # (`homonymOf`, "Nepatří k tomuto interpretovi") nebrat; přednost má
        # interpret s MBID / Deezer id.
        live = [a for a in rows if not {"mergedInto", "homonymOf"} & set((a.external_refs or {}).keys())]
        return max(live, key=lambda a: (a.mbid is not None, a.deezer_id is not None), default=None)

    artist = best(session.exec(select(Artist).where(Artist.name == name)).all())
    if artist is None:
        artist = best(session.exec(select(Artist).where(func.lower(Artist.name) == name.lower())).all())
    if artist is None:
        # Bez diakritiky a velikosti písmen ("KVETY" z tagu -> "Květy"): dřív
        # tu vznikal paralelní interpret a v Knihovně byl dvakrát. Jen když
        # je shoda JEDNOZNAČNÁ (jeden živý kandidát) -- jinak radši nový.
        ids = _folded_index(session).get(fold_name(name), [])
        live = [
            a
            for a in (session.get(Artist, i) for i in ids)
            if a is not None and not {"mergedInto", "homonymOf"} & set((a.external_refs or {}).keys())
        ]
        if len(live) == 1:
            artist = live[0]
    if artist is None:
        artist = Artist(name=name, sort_name=name)
        session.add(artist)
        session.commit()
        session.refresh(artist)
        _folded_index(session).setdefault(fold_name(name), []).append(artist.id)
    return artist


def fold_name(name: str) -> str:
    """Jméno bez diakritiky, velikosti písmen a interpunkce ("KVĚTY" == "Kvety")."""
    text = unicodedata.normalize("NFKD", name)
    text = "".join(ch for ch in text if not unicodedata.combining(ch)).casefold()
    return " ".join("".join(ch if ch.isalnum() else " " for ch in text).split())


_FOLDED: dict[str, list[str]] = {}
_FOLDED_AT = 0.0


def _folded_index(session: Session) -> dict[str, list[str]]:
    """fold_name -> id interpretů; v paměti, obnova po 10 minutách (sken
    knihovny volá hledání pro každý soubor)."""
    import time

    global _FOLDED, _FOLDED_AT
    if not _FOLDED or time.monotonic() - _FOLDED_AT > 600:
        index: dict[str, list[str]] = {}
        for artist_id, artist_name in session.exec(select(Artist.id, Artist.name)).all():
            index.setdefault(fold_name(artist_name or ""), []).append(artist_id)
        _FOLDED, _FOLDED_AT = index, time.monotonic()
    return _FOLDED


def find_or_create_release(session: Session, artist: Artist, title: str) -> Release:
    title = _nfc(title.strip())
    release = session.exec(select(Release).where(Release.artist_id == artist.id, Release.title == title)).first()
    if release is None:
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
    title = _nfc(title.strip())
    recording = session.exec(select(Recording).where(Recording.artist_id == artist.id, Recording.title == title)).first()
    if recording is None:
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
