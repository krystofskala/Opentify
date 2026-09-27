"""RecommendationService — objevování a personalizované mixy z ListenBrainz.

Zdroj pravdy pro "co doporučit" je vždy ListenBrainz; tahle vrstva jen
resolvuje doporučené JSPF tracky do našeho lokálního katalogu (stejný
upsert-by-mbid mechanismus jako CatalogService, viz app.catalog.upsert) a
spočítá `availability`, aby klient mohl doporučenou skladbu rovnou
provisionovat/přehrát ve stejném UI jako běžný katalog.

Pokud ListenBrainz instance neběží, nebo pro daného uživatele ještě
nevygenerovala playlisty (potřebuje pár týdnů poslechové historie — cold
start osobního serveru), obě veřejné metody vrátí prázdný výsledek, ne
chybu. To odpovídá principu "chybějící položka je jen jiný stav" z
docs/ARCHITECTURE.md, ne edge case, který by klient musel řešit speciálně.
"""

from __future__ import annotations

import re
from typing import Any

from sqlmodel import Session, select

from app.catalog.availability import compute_availability
from app.catalog.schemas import RecordingOut
from app.catalog.upsert import upsert_artist, upsert_recording
from app.models import Playlist, PlaylistItem, PlaylistKind, Recording
from app.recommendations.listenbrainz import ListenBrainzClient, ListenBrainzError
from app.recommendations.schemas import PlaylistDetailOut
from app.utils import utcnow

_MB_ENTITY_URL_RE = re.compile(r"/(?:recording|artist)/([0-9a-fA-F-]{36})")


def _mbid_from_identifier(identifier: Any) -> str | None:
    """JSPF `identifier`/`artist_identifiers` bývá buď string, nebo list
    stringů (URL tvaru `https://musicbrainz.org/recording/<mbid>`)."""
    if isinstance(identifier, list):
        identifier = identifier[0] if identifier else None
    if not isinstance(identifier, str):
        return None
    match = _MB_ENTITY_URL_RE.search(identifier)
    return match.group(1) if match else None


class RecommendationService:
    def __init__(self, session: Session, lb_client: ListenBrainzClient) -> None:
        self._session = session
        self._lb = lb_client

    # ------------------------------------------------------------------
    # JSPF track -> lokální Recording
    # ------------------------------------------------------------------

    def _resolve_jspf_track(self, track: dict[str, Any]) -> Recording | None:
        title = track.get("title")
        if not title:
            return None

        recording_mbid = _mbid_from_identifier(track.get("identifier"))
        artist_name = track.get("creator") or "Unknown Artist"
        artist_identifiers = (
            track.get("extension", {})
            .get("https://musicbrainz.org/doc/jspf#track", {})
            .get("artist_identifiers", [])
        )
        artist_mbid = _mbid_from_identifier(artist_identifiers)

        artist = upsert_artist(self._session, mbid=artist_mbid, name=artist_name, sort_name=None)
        return upsert_recording(
            self._session,
            mbid=recording_mbid,
            release_id=None,  # ListenBrainz playlisty nenesou album kontext
            artist_id=artist.id,
            title=title,
            duration_ms=track.get("duration"),
            isrc=None,
            track_number=None,
        )

    def _to_recording_out(self, recording: Recording) -> RecordingOut:
        return RecordingOut(
            id=recording.id,
            mbid=recording.mbid,
            release_id=recording.release_id,
            artist_id=recording.artist_id,
            title=recording.title,
            duration_ms=recording.duration_ms,
            isrc=recording.isrc,
            track_number=recording.track_number,
            availability=compute_availability(self._session, recording.id),
            preview_url=recording.external_refs.get("previewUrl"),
        )

    async def _fetch_patch_tracks(
        self, user_name: str, source_patch: str
    ) -> list[dict[str, Any]]:
        try:
            playlist_mbid = await self._lb.find_playlist_mbid_by_patch(user_name, source_patch)
            if playlist_mbid is None:
                return []
            jspf = await self._lb.get_playlist(playlist_mbid)
        except ListenBrainzError:
            return []
        return jspf.get("playlist", {}).get("track", [])

    # ------------------------------------------------------------------
    # Veřejné API
    # ------------------------------------------------------------------

    async def discover(self, user_name: str, limit: int) -> list[RecordingOut]:
        tracks = await self._fetch_patch_tracks(user_name, "weekly-exploration")
        recordings = [
            r for r in (self._resolve_jspf_track(t) for t in tracks[:limit]) if r is not None
        ]
        return [self._to_recording_out(r) for r in recordings]

    async def daily_jams(self, user_id: str, user_name: str) -> PlaylistDetailOut:
        tracks = await self._fetch_patch_tracks(user_name, "daily-jams")

        playlist = self._session.exec(
            select(Playlist).where(
                Playlist.owner_user_id == user_id,
                Playlist.source == "listenbrainz:daily-jams",
            )
        ).first()
        if playlist is None:
            playlist = Playlist(
                owner_user_id=user_id,
                title="Daily Jams",
                kind=PlaylistKind.GENERATED_RECOMMENDATION,
                source="listenbrainz:daily-jams",
            )
            self._session.add(playlist)
            self._session.commit()
            self._session.refresh(playlist)

        # daily-jams je denně přegenerovaný snapshot, ne playlist s historií
        # ručních editací -> položky se při každém zavolání nahrazují celé.
        old_items = self._session.exec(
            select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)
        ).all()
        for item in old_items:
            self._session.delete(item)
        self._session.commit()

        recordings: list[Recording] = []
        for position, track in enumerate(tracks):
            recording = self._resolve_jspf_track(track)
            if recording is None:
                continue
            self._session.add(
                PlaylistItem(playlist_id=playlist.id, recording_id=recording.id, position=position)
            )
            recordings.append(recording)

        playlist.generated_at = utcnow()
        playlist.updated_at = utcnow()
        self._session.add(playlist)
        self._session.commit()

        return PlaylistDetailOut(
            id=playlist.id,
            title=playlist.title,
            kind=playlist.kind,
            source=playlist.source,
            generated_at=playlist.generated_at,
            item_count=len(recordings),
            items=[self._to_recording_out(r) for r in recordings],
        )
