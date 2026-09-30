"""Interpreti z vlastní hudby (soubory z PC bez MusicBrainz/Deezer id) se
nesmí na Deezer párovat jen podle jména -- kapel stejného jména bývá víc
(živě: tátova kapela Kontrast by dostala cizí fotku, diskografii i
nejhranější skladby). Kandidát projde jen s ověřením: aspoň jedno jeho
album se jmenuje stejně jako některé naše album toho interpreta.
"""

from __future__ import annotations

import unicodedata

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, MediaAsset, Recording, Release

_OWN_PROVIDERS = ("local", "musicbrainz-local")


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
