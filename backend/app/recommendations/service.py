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

import random
import re
from typing import Any

from sqlmodel import Session, select

from app.catalog.availability import compute_availability
from app.catalog.cache import cached_json
from app.catalog.schemas import RecordingOut
from app.catalog.upsert import upsert_artist, upsert_recording
from app.library.spotify_import import LIKED_SONGS_SOURCE
from app.models import Playlist, PlaylistItem, PlaylistKind, Recording
from app.recommendations.listenbrainz import (
    ListenBrainzClient,
    ListenBrainzError,
    ListenBrainzPublicClient,
)
from app.recommendations.schemas import PlaylistDetailOut
from app.utils import utcnow

TRENDING_RESOLVED_TTL_SECONDS = 60 * 60
COMMUNITY_RESOLVED_TTL_SECONDS = 60 * 60
PERSONAL_DAILY_JAMS_SOURCE = "personal:daily-jams"
PERSONAL_DAILY_JAMS_LIMIT = 20

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
    def __init__(
        self,
        session: Session,
        lb_client: ListenBrainzClient,
        lb_public_client: ListenBrainzPublicClient | None = None,
    ) -> None:
        self._session = session
        self._lb = lb_client
        self._lb_public = lb_public_client

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

    def _to_recording_out(self, recording: Recording, listen_count: int | None = None) -> RecordingOut:
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
            listen_count=listen_count,
        )

    # ------------------------------------------------------------------
    # ListenBrainz stats (sitewide/user) -> lokální Recording
    # ------------------------------------------------------------------

    def _resolve_stats_entry(self, entry: dict[str, Any]) -> Recording | None:
        """`entry` je jedna položka z `/1/stats/sitewide/recordings` nebo
        `/1/stats/user/{name}/recordings` -- stejný tvar u obou. Stejně jako
        u JSPF (`_resolve_jspf_track`) záměrně nedosazujeme `release_id`:
        LB stats nesou konkrétní release MBID (edici), zatímco náš `Release`
        odpovídá MusicBrainz release-*group* -- namapovat jedno na druhé bez
        dalšího MB dotazu by riskovalo duplicitní/nesprávně sloučené řádky.
        """
        title = entry.get("track_name")
        if not title:
            return None
        artist_mbids = entry.get("artist_mbids") or []
        artist = upsert_artist(
            self._session,
            mbid=artist_mbids[0] if artist_mbids else None,
            name=entry.get("artist_name") or "Unknown Artist",
            sort_name=None,
        )
        return upsert_recording(
            self._session,
            mbid=entry.get("recording_mbid"),
            release_id=None,
            artist_id=artist.id,
            title=title,
            duration_ms=None,
            isrc=None,
            track_number=None,
        )

    async def _resolve_stats_entries_cached(
        self, cache_key: str, limit: int, fetch_entries: Any
    ) -> list[RecordingOut]:
        """Společné jádro `trending`/`community_picks`: samotné rozřešení do
        lokálního katalogu (upsert) se cachuje jako seznam `recordingId` —
        jinak by každé znovunačtení Home obrazovky během LB TTL okna znova
        upsertovalo stejné bez-mbid položky a hromadilo duplicitní řádky
        (`upsert_recording` bez `mbid` vždy založí nový záznam). `availability`
        se naopak počítá vždy živě z aktuální DB, ne z cache."""

        async def resolve_and_cache() -> list[dict[str, Any]]:
            entries = await fetch_entries()
            resolved: list[dict[str, Any]] = []
            seen: set[str] = set()
            for entry in entries:
                if len(resolved) >= limit:
                    break
                recording = self._resolve_stats_entry(entry)
                if recording is None or recording.id in seen:
                    continue
                seen.add(recording.id)
                resolved.append({"recordingId": recording.id, "listenCount": entry.get("listen_count")})
            return resolved

        resolved = await cached_json(cache_key, TRENDING_RESOLVED_TTL_SECONDS, resolve_and_cache)

        results: list[RecordingOut] = []
        for item in resolved:
            recording = self._session.get(Recording, item["recordingId"])
            if recording is None:
                continue  # řádek mezitím zmizel (mělo by být vzácné) -- prostě přeskočit
            results.append(self._to_recording_out(recording, listen_count=item.get("listenCount")))
        return results

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

    def _liked_songs_recordings(self, user_id: str) -> list[Recording]:
        playlist = self._session.exec(
            select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
        ).first()
        if playlist is None:
            return []
        items = self._session.exec(
            select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id).order_by(PlaylistItem.position)
        ).all()
        recordings = [self._session.get(Recording, item.recording_id) for item in items]
        return [r for r in recordings if r is not None]

    def _daily_sample(self, recordings: list[Recording], limit: int) -> list[Recording]:
        """Stejný den -> stejný výběr (seed = dnešní datum), jiný den ->
        jiný -- žádné ML doporučování, jen deterministicky zamíchaná vlastní
        knihovna, aby "denní mix" reálně měnil obsah den ze dne."""
        if len(recordings) <= limit:
            return recordings
        rng = random.Random(str(utcnow().date()))
        return rng.sample(recordings, limit)

    def _build_daily_jams_snapshot(
        self, user_id: str, source: str, recordings: list[Recording]
    ) -> PlaylistDetailOut:
        playlist = self._session.exec(
            select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == source)
        ).first()
        if playlist is None:
            playlist = Playlist(
                owner_user_id=user_id,
                title="Daily Jams",
                kind=PlaylistKind.GENERATED_RECOMMENDATION,
                source=source,
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

        for position, recording in enumerate(recordings):
            self._session.add(
                PlaylistItem(playlist_id=playlist.id, recording_id=recording.id, position=position)
            )

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

    async def daily_jams(self, user_id: str, user_name: str) -> PlaylistDetailOut:
        """Denní mix -- přednostně z uživatelovy vlastní knihovny (Liked Songs
        naimportované ze Spotify, viz app.library.spotify_import), protože na
        rozdíl od ListenBrainz JSPF "daily-jams" patche (vyžaduje reálný účet
        na listenbrainz.org s poslechovou historií) tahle data server už má
        rovnou. Padá zpět na ListenBrainz, jen dokud uživatel žádnou knihovnu
        nenaimportoval -- ne proto, že by byl horší zdroj, ale aby appka
        nebyla úplně prázdná od první minuty.
        """
        liked = self._liked_songs_recordings(user_id)
        if liked:
            sample = self._daily_sample(liked, PERSONAL_DAILY_JAMS_LIMIT)
            return self._build_daily_jams_snapshot(user_id, PERSONAL_DAILY_JAMS_SOURCE, sample)

        tracks = await self._fetch_patch_tracks(user_name, "daily-jams")
        recordings = [r for r in (self._resolve_jspf_track(t) for t in tracks) if r is not None]
        return self._build_daily_jams_snapshot(user_id, "listenbrainz:daily-jams", recordings)

    async def trending(self, limit: int, range_: str = "week") -> list[RecordingOut]:
        """"Populární na serveru" -- ve skutečnosti sitewide žebříček celé
        veřejné komunity ListenBrainz (https://api.listenbrainz.org), ne dat
        z týhle instance (ta žádné poslechy nesleduje, viz docs/ARCHITECTURE.md
        otevřená otázka #3 o single- vs multi-user). Prázdné, pokud
        listenbrainz.org neodpoví (výpadek/rate limit) -- stejná "chybějící
        položka je jen jiný stav" filosofie jako `discover`/`daily_jams`."""
        if self._lb_public is None:
            return []

        async def fetch_entries() -> list[dict[str, Any]]:
            try:
                return await self._lb_public.sitewide_top_recordings(range_, limit)
            except ListenBrainzError:
                return []

        return await self._resolve_stats_entries_cached(f"trending:{range_}:{limit}", limit, fetch_entries)

    async def my_top_tracks(self, user_name: str, limit: int, range_: str = "month") -> list[RecordingOut]:
        """"Moje nejposlouchanější" -- na rozdíl od `daily_jams`/`discover`
        (čekají na troi patch, který ListenBrainz běží dávkově a jen pro
        dostatečně aktivní účty) čte přímo `/1/stats/user/{name}/recordings`
        -- funguje, jakmile má účet vůbec nějaké zaznamenané poslechy, i bez
        vygenerovaného doporučení. Prázdné (LB vrací 204), dokud účet nemá
        dost poslechů na spočtenou statistiku -- legitimní stav, ne chyba."""
        if self._lb_public is None:
            return []

        async def fetch_entries() -> list[dict[str, Any]]:
            try:
                return await self._lb_public.user_top_recordings(user_name, range_, limit)
            except ListenBrainzError:
                return []

        return await self._resolve_stats_entries_cached(f"my-top:{user_name}:{range_}:{limit}", limit, fetch_entries)

    async def community_picks(self, user_name: str, limit: int) -> list[RecordingOut]:
        """"Komunitní objevy" -- top nahrávky uživatelů s podobným vkusem
        (`similar-users`) na veřejném ListenBrainz. Vyžaduje, aby
        `LISTENBRAINZ_USERNAME` byl skutečný účet na listenbrainz.org
        s poslechovou historií -- pro `demo-user`/self-hosted-only jméno
        vrátí prázdno, což je legitimní stav, ne chyba."""
        if self._lb_public is None:
            return []

        async def fetch_entries() -> list[dict[str, Any]]:
            try:
                peers = await self._lb_public.similar_users(user_name, count=3)
            except ListenBrainzError:
                return []
            entries: list[dict[str, Any]] = []
            for peer in peers:
                peer_name = peer.get("user_name")
                if not peer_name:
                    continue
                try:
                    entries.extend(await self._lb_public.user_top_recordings(peer_name, "month", limit))
                except ListenBrainzError:
                    continue
            return entries

        return await self._resolve_stats_entries_cached(f"community:{user_name}:{limit}", limit, fetch_entries)
