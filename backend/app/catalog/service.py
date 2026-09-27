"""CatalogService — jediný vstupní bod, který routy (app/routes/catalog.py)
volají. Zodpovědnosti:

1. Dotázat MusicBrainz na strukturu (interpreti/alba/nahrávky) a Deezer na
   doplňková metadata (cover art, 30s náhledy) — obojí přes cachované,
   rate-limitované adaptéry v tomto balíčku.
2. Upsertnout výsledky do lokálních Artist/Release/Recording tabulek. Tím
   entita získá stabilní lokální `id`, na které se dá později zavolat
   `POST /tracks/{id}/provision` — bez tohoto kroku by "provisionable"
   položka z vyhledávání nešla vůbec provisionovat.
3. Spočítat `availability` proti MediaAsset (app.catalog.availability).

Deezer enrichment (obrázky, preview) je záměrně *ne*volaný v `search()` —
u N výsledků by šlo o N dalších externích requestů na jeden dotaz. Dělá se
až na detailu interpreta/alba/tracklistu, kde je entit málo a request je
vyvolaný explicitním otevřením obrazovky, ne psaním do vyhledávacího pole.
"""

from __future__ import annotations

import asyncio
from typing import Any

from sqlmodel import Session

from app.catalog.availability import compute_availability
from app.catalog.deezer import DeezerClient
from app.catalog.musicbrainz import MusicBrainzClient, MusicBrainzError
from app.catalog.schemas import ArtistOut, DiscographyOut, ReleaseOut, RecordingOut
from app.catalog.upsert import upsert_artist, upsert_recording, upsert_release
from app.models import Artist, Recording, Release

_MB_ENTITY_FOR_TYPE = {
    "artist": "artist",
    "release": "release-group",
    "recording": "recording",
}

_MB_PRIMARY_TYPE_TO_RELEASE_TYPE = {
    "album": "album",
    "single": "single",
    "ep": "ep",
}


def _parse_track_number(raw: str | None) -> int | None:
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None  # vinyl/kazetová strana jako "A1" apod. — bez číselného pořadí


class CatalogService:
    def __init__(
        self,
        session: Session,
        mb_client: MusicBrainzClient,
        deezer_client: DeezerClient,
    ) -> None:
        self._session = session
        self._mb = mb_client
        self._dz = deezer_client

    # ------------------------------------------------------------------
    # MB JSON -> lokální řádky (upsert samotný žije v app.catalog.upsert,
    # sdílený s RecommendationService)
    # ------------------------------------------------------------------

    def _ingest_artist_credit(self, artist_credit: list[dict[str, Any]] | None) -> Artist | None:
        if not artist_credit:
            return None
        primary = artist_credit[0].get("artist", {})
        if not primary.get("name"):
            return None
        return upsert_artist(
            self._session,
            mbid=primary.get("id"),
            name=primary["name"],
            sort_name=primary.get("sort-name"),
        )

    def _ingest_release_group_json(self, rg: dict[str, Any]) -> Release | None:
        artist = self._ingest_artist_credit(rg.get("artist-credit"))
        if artist is None:
            return None
        primary_type = (rg.get("primary-type") or "album").lower()
        secondary_types = [t.lower() for t in rg.get("secondary-types", [])]
        if "compilation" in secondary_types:
            release_type = "compilation"
        else:
            release_type = _MB_PRIMARY_TYPE_TO_RELEASE_TYPE.get(primary_type, "album")
        return upsert_release(
            self._session,
            mbid=rg.get("id"),
            artist_id=artist.id,
            title=rg.get("title", "Untitled"),
            release_date=rg.get("first-release-date") or None,
            release_type=release_type,
        )

    def _ingest_recording_search_json(self, rec: dict[str, Any]) -> Recording | None:
        if not rec.get("title"):
            return None
        artist = self._ingest_artist_credit(rec.get("artist-credit"))
        release_id = None
        releases = rec.get("releases") or []
        if releases:
            rg = releases[0].get("release-group")
            if rg and rg.get("id"):
                release = self._ingest_release_group_json(
                    {**rg, "artist-credit": rec.get("artist-credit")}
                )
                release_id = release.id if release else None
        isrcs = rec.get("isrcs") or []
        return upsert_recording(
            self._session,
            mbid=rec.get("id"),
            release_id=release_id,
            artist_id=artist.id if artist else None,
            title=rec["title"],
            duration_ms=rec.get("length"),
            isrc=isrcs[0] if isrcs else None,
            track_number=None,
        )

    # ------------------------------------------------------------------
    # DTO builders
    # ------------------------------------------------------------------

    def _to_artist_out(self, artist: Artist) -> ArtistOut:
        return ArtistOut(
            id=artist.id,
            mbid=artist.mbid,
            deezer_id=artist.deezer_id,
            name=artist.name,
            sort_name=artist.sort_name,
            images=artist.images,
        )

    def _to_release_out(self, release: Release) -> ReleaseOut:
        return ReleaseOut(
            id=release.id,
            mbid=release.mbid,
            artist_id=release.artist_id,
            title=release.title,
            release_date=release.release_date,
            release_type=release.release_type,
            images=release.images,
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

    # ------------------------------------------------------------------
    # Veřejné API
    # ------------------------------------------------------------------

    async def search(
        self, query: str, entity_type: str | None, limit: int, offset: int
    ) -> dict[str, Any]:
        types_to_query = [entity_type] if entity_type else list(_MB_ENTITY_FOR_TYPE)

        async def search_one(t: str) -> tuple[str, dict[str, Any]]:
            try:
                data = await self._mb.search(_MB_ENTITY_FOR_TYPE[t], query, limit, offset)
            except MusicBrainzError:
                data = {}
            return t, data

        raw_results = await asyncio.gather(*(search_one(t) for t in types_to_query))

        results: list[dict[str, Any]] = []
        for t, data in raw_results:
            if t == "artist":
                for a in data.get("artists", []):
                    artist = upsert_artist(
                        self._session,
                        mbid=a.get("id"),
                        name=a.get("name", "Unknown"),
                        sort_name=a.get("sort-name"),
                    )
                    results.append(
                        {"entityType": "artist", **self._to_artist_out(artist).model_dump(by_alias=True)}
                    )
            elif t == "release":
                for rg in data.get("release-groups", []):
                    release = self._ingest_release_group_json(rg)
                    if release is not None:
                        results.append(
                            {
                                "entityType": "release",
                                **self._to_release_out(release).model_dump(by_alias=True),
                            }
                        )
            elif t == "recording":
                for rec in data.get("recordings", []):
                    recording = self._ingest_recording_search_json(rec)
                    if recording is not None:
                        results.append(
                            {
                                "entityType": "recording",
                                **self._to_recording_out(recording).model_dump(by_alias=True),
                            }
                        )

        # Kombinovaný multi-entity dotaz (bez `type`) stránkuje každý typ
        # samostatně na backendu MB, ne agregát — pro osobní použití (malé `limit`,
        # žádné hluboké listování) je to dostatečné zjednodušení; přesná
        # cross-entity paginace by čekala na skutečnou potřebu.
        return {"query": query, "total": len(results), "results": results[: limit or len(results)]}

    async def get_artist(self, artist_id: str) -> ArtistOut | None:
        artist = self._session.get(Artist, artist_id)
        if artist is None:
            return None
        await self._enrich_artist_images(artist)
        return self._to_artist_out(artist)

    async def get_discography(
        self, artist_id: str, release_type: str | None
    ) -> DiscographyOut | None:
        artist = self._session.get(Artist, artist_id)
        if artist is None or artist.mbid is None:
            return None

        try:
            data = await self._mb.browse_release_groups(
                artist.mbid, release_type, limit=100, offset=0
            )
        except MusicBrainzError:
            data = {}

        releases: list[Release] = []
        for rg in data.get("release-groups", []):
            # Browse (na rozdíl od search) nevrací `artist-credit` -- interpret
            # je jistý z kontextu dotazu, doplníme ho manuálně.
            rg_with_artist = {
                **rg,
                "artist-credit": [{"artist": {"id": artist.mbid, "name": artist.name, "sort-name": artist.sort_name}}],
            }
            release = self._ingest_release_group_json(rg_with_artist)
            if release is not None:
                releases.append(release)

        releases.sort(key=lambda r: r.release_date or "9999")
        return DiscographyOut(
            artist=self._to_artist_out(artist),
            releases=[self._to_release_out(r) for r in releases],
        )

    async def get_release(self, release_id: str) -> ReleaseOut | None:
        release = self._session.get(Release, release_id)
        if release is None:
            return None
        await self._enrich_release_images(release)
        return self._to_release_out(release)

    async def get_release_tracks(self, release_id: str) -> list[RecordingOut] | None:
        release = self._session.get(Release, release_id)
        if release is None:
            return None
        if release.mbid is None:
            return []

        try:
            data = await self._mb.get_release_group_tracks(release.mbid)
        except MusicBrainzError:
            return []

        mb_releases = data.get("releases") or []
        if not mb_releases:
            return []
        chosen = mb_releases[0]  # jedna kanonická edice stačí pro osobní katalog

        recordings: list[Recording] = []
        for medium in chosen.get("media", []):
            for track in medium.get("tracks", []):
                rec_json = track.get("recording", {})
                title = rec_json.get("title") or track.get("title")
                if not title:
                    continue
                isrcs = rec_json.get("isrcs") or []
                recording = upsert_recording(
                    self._session,
                    mbid=rec_json.get("id") or track.get("id"),
                    release_id=release.id,
                    artist_id=release.artist_id,
                    title=title,
                    duration_ms=rec_json.get("length") or track.get("length"),
                    isrc=isrcs[0] if isrcs else None,
                    track_number=_parse_track_number(track.get("number")),
                )
                recordings.append(recording)

        await self._enrich_recording_previews(recordings)
        recordings.sort(key=lambda r: (r.track_number is None, r.track_number or 0))
        return [self._to_recording_out(r) for r in recordings]

    async def match_recording_by_text(self, query: str) -> Recording | None:
        """Najde a napojí nahrávku na MusicBrainz podle volného textu (typicky
        "interpret název" z ID3 tagů) -- používá `app/library/scanner.py` pro
        lokální soubory se špatnými/chybějícími/nesouvisejícími názvy složek:
        na rozdíl od jména souboru MusicBrainz search výsledek nezávisí na
        tom, jak je track lokálně pojmenovaný. Vezme jen první (nejrelevantnější)
        výsledek -- žádné ruční rozhodování mezi kandidáty, stejné zjednodušení
        jako `search()` bere search výsledky tak, jak přijdou z MB."""
        try:
            data = await self._mb.search("recording", query, limit=1, offset=0)
        except MusicBrainzError:
            return None
        recordings = data.get("recordings", [])
        if not recordings:
            return None
        return self._ingest_recording_search_json(recordings[0])

    # ------------------------------------------------------------------
    # Deezer enrichment — best-effort, nikdy nesmí shodit request na MB datech.
    # ------------------------------------------------------------------

    async def _enrich_artist_images(self, artist: Artist) -> None:
        if artist.images:
            return
        try:
            data = await self._dz.search(artist.name, limit=1)
        except Exception:
            return
        if not data or not data.get("data"):
            return
        picture = data["data"][0].get("artist", {}).get("picture_xl")
        if picture:
            artist.images = [picture]
            self._session.add(artist)
            self._session.commit()

    async def _enrich_release_images(self, release: Release) -> None:
        if release.images:
            return
        artist = self._session.get(Artist, release.artist_id)
        if artist is None:
            return
        try:
            data = await self._dz.search(f"{artist.name} {release.title}", limit=1)
        except Exception:
            return
        if not data or not data.get("data"):
            return
        cover = data["data"][0].get("album", {}).get("cover_xl")
        if cover:
            release.images = [cover]
            self._session.add(release)
            self._session.commit()

    async def _enrich_recording_previews(self, recordings: list[Recording]) -> None:
        """Zapíše Deezer `preview_url` do `external_refs["previewUrl"]` pro
        skladby, které mají ISRC. Best-effort a paralelně, protože jde o
        desítky nezávislých lookupů (jeden album tracklist)."""

        async def enrich_one(recording: Recording) -> None:
            if not recording.isrc or recording.external_refs.get("previewUrl"):
                return
            try:
                track = await self._dz.find_track_by_isrc(recording.isrc)
            except Exception:
                return
            if track and track.get("preview"):
                recording.external_refs = {**recording.external_refs, "previewUrl": track["preview"]}
                self._session.add(recording)

        await asyncio.gather(*(enrich_one(r) for r in recordings))
        self._session.commit()
