"""Interpreti z vlastní hudby (soubory z PC bez MusicBrainz/Deezer id) se
nesmí na Deezer párovat jen podle jména -- kapel stejného jména bývá víc
(živě: tátova kapela Kontrast by dostala cizí fotku, diskografii i
nejhranější skladby). Kandidát projde jen s ověřením: aspoň jedno jeho
album se jmenuje stejně jako některé naše album toho interpreta.
"""

from __future__ import annotations

import time
import unicodedata

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, MediaAsset, Recording, Release

_OWN_PROVIDERS = ("local", "musicbrainz-local")

# "Vlastní" interpret/album/skladba (tátova kapela...): místo skutečných id
# z MusicBrainz/Deezeru trvalá zástupná `own:<id>`. Kód páruje podle jména
# jen řádky BEZ id a id porovnává přesně -- takový řádek se tak s nikým
# nespojí a stejnojmenná cizí kapela vznikne jako samostatný interpret.
# Klienti MusicBrainz/Deezer/ListenBrainz/fanart/CAA s ním nikam nevolají.
OWN_PREFIX = "own:"


def is_own_id(value: str | None) -> bool:
    return isinstance(value, str) and value.startswith(OWN_PREFIX)


def is_own_artist(artist: Artist | str | None) -> bool:
    """Vlastní interpret (`own:` id / `ownArtist`; řádek nebo jeho id) --
    podle jména ho nikde nehledat (Last.fm, Discogs...), našla by se
    stejnojmenná cizí kapela."""
    if artist is None:
        return False
    if isinstance(artist, str):
        return artist in own_artist_ids()
    refs = artist.external_refs or {}
    return is_own_id(artist.mbid) or is_own_id(artist.deezer_id) or bool(refs.get("ownArtist"))


def own_styles(artist_id: str) -> list[str]:
    """Ručně zadané styly vlastního interpreta (`external_refs.styles`, např.
    Kontrast = bluegrass, czech bluegrass). Last.fm podle jména by vrátil
    cizí kapelu (Kontrast -> německé EBM), tak se berou tyhle."""
    from sqlmodel import Session

    from app.db import engine

    with Session(engine) as session:
        artist = session.get(Artist, artist_id)
        styles = ((artist.external_refs or {}).get("styles") if artist else None) or []
    return [str(s).lower() for s in styles if s]


_OWN_IDS: set[str] = set()
_OWN_IDS_AT = -1e9


def own_artist_ids() -> set[str]:
    """Id vlastních interpretů (krátká cache -- volá se pro každé jméno)."""
    global _OWN_IDS, _OWN_IDS_AT
    if time.monotonic() - _OWN_IDS_AT > 300:
        with Session(engine) as session:
            rows = session.exec(
                select(Artist).where(
                    ((Artist.mbid >= OWN_PREFIX) & (Artist.mbid < "own;"))  # type: ignore[operator]
                    | ((Artist.deezer_id >= OWN_PREFIX) & (Artist.deezer_id < "own;"))  # type: ignore[operator]
                )
            ).all()
            _OWN_IDS = {a.id for a in rows if is_own_artist(a)}
        _OWN_IDS_AT = time.monotonic()
    return _OWN_IDS


def _norm(text: str | None) -> str:
    return unicodedata.normalize("NFKD", text or "").encode("ascii", "ignore").decode().lower().strip()


def local_only_artist(name: str) -> Artist | None:
    """Interpret toho jména, který známe JEN z vlastních souborů (bez id
    z MusicBrainz/Deezeru), nebo `None`."""
    with Session(engine) as session:
        for artist in session.exec(select(Artist).where(Artist.name == name)).all():
            if artist.mbid or artist.deezer_id:
                continue
            own = session.exec(
                select(MediaAsset.recording_id)
                .join(Recording, Recording.id == MediaAsset.recording_id)
                .where(Recording.artist_id == artist.id, MediaAsset.source_provider.in_(_OWN_PROVIDERS))  # type: ignore[union-attr]
            ).first()
            if own is not None:
                session.expunge(artist)
                return artist
    return None


def own_album_titles(artist_id: str) -> set[str]:
    with Session(engine) as session:
        return {_norm(r.title) for r in session.exec(select(Release).where(Release.artist_id == artist_id)).all()}


async def verified_deezer_artist(artist: Artist, candidates: list[dict]) -> dict | None:
    """Kandidát z Deezeru, jehož alba se aspoň v jednom názvu shodují
    s našimi alby toho interpreta; jinak `None`."""
    from app.catalog.deezer import get_deezer_client

    ours = own_album_titles(artist.id)
    if not ours:
        return None
    dz = get_deezer_client()
    for candidate in candidates:
        if not candidate.get("id") or _norm(candidate.get("name")) != _norm(artist.name):
            continue
        albums = await dz.artist_albums(str(candidate["id"])) or []
        if any(_norm(a.get("title")) in ours for a in albums):
            return candidate
    return None
