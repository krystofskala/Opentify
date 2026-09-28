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
import re
import unicodedata
from typing import Any

from sqlmodel import Session

from app.catalog.artwork import fill_artist, fill_release
from app.catalog.availability import compute_availability, resolve_artist_name
from app.catalog.deezer import DeezerClient
from app.catalog.musicbrainz import MusicBrainzClient, MusicBrainzError
from app.catalog.schemas import ArtistBioOut, ArtistOut, DiscographyOut, ReleaseOut, RecordingOut
from app.catalog.upsert import upsert_artist, upsert_recording, upsert_release
from app.catalog.wikimedia import get_wikimedia_client
from app.models import Artist, Recording, Release

_TRACKLIST_OVERLAP_THRESHOLD = 0.4
_TRACKLIST_CANDIDATE_LIMIT = 3
_PARENS_RE = re.compile(r"\(.*?\)|\[.*?\]")
_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")


def normalize_title(title: str) -> str:
    """Sundá diakritiku, závorkové dovětky ("(Remastered 2011)", "(feat. X)")
    a interpunkci -- dost na porovnání "stejná skladba, jiný zápis", ne na
    plnou fuzzy shodu překlepů (na to viz `_TRACKLIST_OVERLAP_THRESHOLD`,
    který toleruje část tracklistu, co takhle stejně nesedne)."""
    text = unicodedata.normalize("NFKD", title).encode("ascii", "ignore").decode("ascii").lower()
    text = _PARENS_RE.sub(" ", text)
    text = _NON_ALNUM_RE.sub(" ", text)
    return text.strip()


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
            # Embedded artist-credit stub (search/browse výsledky) `country`
            # typicky nenese vůbec -- `.get()` je tu jen pro tu vzácnou
            # odpověď, co ho náhodou obsahuje. Spolehlivá cesta je
            # `_enrich_artist_country` přes samostatný `/artist/{mbid}` lookup.
            country=primary.get("country"),
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
            # Jen search/browse odpovědi s `inc=genres` tohle pole vůbec
            # nesou (viz `browse_release_groups`/`get_release_group`) --
            # jinde `rg.get("genres")` prostě chybí a `upsert_release` starou
            # hodnotu nepřepíše (viz jeho "nepřepisovat prázdným" komentář).
            genres=[g["name"] for g in rg.get("genres", []) if g.get("name")],
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
            artist_name=resolve_artist_name(self._session, recording.artist_id),
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

        async def search_one(t: str) -> tuple[str, dict[str, Any] | None]:
            try:
                data = await self._mb.search(_MB_ENTITY_FOR_TYPE[t], query, limit, offset)
            except MusicBrainzError:
                # `None` (ne `{}`) -- ať to jde odlišit od "MB opravdu nic
                # nenašel". Dřívější `data = {}` dělalo z dočasného výpadku/
                # rate-limitu (503) tichých "0 výsledků", nerozeznatelných od
                # skutečně neexistující skladby (viz živý test na 15 písničkách,
                # kde přesně tohle způsobilo falešné "nenalezeno" u půlky z nich).
                return t, None
            return t, data

        raw_results = await asyncio.gather(*(search_one(t) for t in types_to_query))

        failed_types = [t for t, data in raw_results if data is None]
        if failed_types and len(failed_types) == len(types_to_query):
            # Všechny dotazované typy selhaly na chybu MusicBrainz -- routa
            # tohle namapuje na 503, aby klient (a uživatel) věděl, že má
            # zkusit znovu, místo aby to vypadalo jako "tahle skladba
            # neexistuje". Částečné selhání (jen některý typ u multi-entity
            # dotazu bez `type`) níž jen ten typ přeskočí -- zbytek výsledků
            # má smysl vrátit.
            raise MusicBrainzError(
                f"MusicBrainz search selhal pro všechny dotazované typy ({failed_types}) u '{query}'"
            )

        results: list[dict[str, Any]] = []
        for t, data in raw_results:
            if data is None:
                continue
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
        await self._enrich_artist_country(artist)
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

    async def get_artist_bio(self, artist_id: str) -> ArtistBioOut | None:
        """Životopis + "Podobní interpreti" pro `ArtistScreen` -- MusicBrainz
        strukturu nemá přímo, jen odkazy (`relations`, viz rozšířený `inc` v
        `MusicBrainzClient.get_artist`). Wikidata/Wikipedia dotaz je
        best-effort stejně jako Deezer enrichment výš -- chybějící životopis
        nebo přerušené externí API nikdy nesmí shodit celou obrazovku
        interpreta, jen se `bio` vrátí `None`."""
        artist = self._session.get(Artist, artist_id)
        if artist is None:
            return None
        if artist.mbid is None:
            return ArtistBioOut(bio=None, related_artists=[])

        try:
            data = await self._mb.get_artist(artist.mbid)
        except MusicBrainzError:
            return ArtistBioOut(bio=None, related_artists=[])

        relations = data.get("relations") or []

        bio: str | None = None
        wikidata_qid = self._extract_wikidata_qid(relations)
        if wikidata_qid is not None:
            wiki = get_wikimedia_client()
            bio = await wiki.get_bio_from_wikidata(wikidata_qid)

        related = self._upsert_related_artists(relations)
        return ArtistBioOut(bio=bio, related_artists=[self._to_artist_out(a) for a in related])

    def _extract_wikidata_qid(self, relations: list[dict[str, Any]]) -> str | None:
        for rel in relations:
            if rel.get("type") != "wikidata":
                continue
            resource = (rel.get("url") or {}).get("resource", "")
            # `https://www.wikidata.org/wiki/Q123` -> `Q123`.
            qid = resource.rsplit("/", 1)[-1]
            if qid.startswith("Q"):
                return qid
        return None

    _RELATED_ARTIST_LIMIT = 8

    def _upsert_related_artists(self, relations: list[dict[str, Any]]) -> list[Artist]:
        """`artist-rels` pokrývá různé vztahy (člen kapely, spolupráce,
        přejmenování...) -- appce jde jen o "je to nějaký propojený
        interpret", ne o rozlišení druhu vztahu, takže bereme všechny
        `target-type == artist`. Dedup podle MBID, limit ať "Podobní
        interpreti" nezabere celou obrazovku u interpretů s desítkami vztahů
        (např. velké kapely s mnoha bývalými členy)."""
        seen_mbids: set[str] = set()
        related: list[Artist] = []
        for rel in relations:
            if rel.get("target-type") != "artist":
                continue
            stub = rel.get("artist") or {}
            mbid = stub.get("id")
            name = stub.get("name")
            if not mbid or not name or mbid in seen_mbids:
                continue
            seen_mbids.add(mbid)
            related.append(
                upsert_artist(self._session, mbid=mbid, name=name, sort_name=stub.get("sort-name"))
            )
            if len(related) >= self._RELATED_ARTIST_LIMIT:
                break
        return related

    async def get_release(self, release_id: str) -> ReleaseOut | None:
        release = self._session.get(Release, release_id)
        if release is None:
            return None
        await self._enrich_release_images(release)
        await self._enrich_release_genres(release)
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

    async def match_release_by_tracklist(
        self, artist_hint: str | None, album_hint: str, local_titles: list[str]
    ) -> tuple[Release, list[Recording]] | None:
        """Najde album podle překryvu CELÉHO tracklistu se složkou lokálních
        souborů, ne jen vyhledáním jedné skladby (`match_recording_by_text`) --
        ten je nespolehlivý pro krátké/nejednoznačné názvy a časté remaster
        varianty, což byl hlavní důvod, proč "hodně alb nebylo rozpoznáno".
        Používá `app/library/scanner.py` pro složky s víc soubory (pravděpodobně
        celé album). Vrací `None`, pokud žádný kandidát nemá dost vysoký
        překryv -- radši žádný match než špatný.
        """
        query = f"{artist_hint} {album_hint}".strip() if artist_hint else album_hint
        if not query:
            return None
        try:
            data = await self._mb.search("release-group", query, _TRACKLIST_CANDIDATE_LIMIT, 0)
        except MusicBrainzError:
            return None
        candidates = data.get("release-groups", [])
        if not candidates:
            return None

        normalized_local = {normalize_title(t) for t in local_titles if t}
        if not normalized_local:
            return None

        best_overlap = 0.0
        best_rg: dict[str, Any] | None = None
        for rg in candidates:
            rgid = rg.get("id")
            if not rgid:
                continue
            try:
                tracks_data = await self._mb.get_release_group_tracks(rgid)
            except MusicBrainzError:
                continue
            mb_releases = tracks_data.get("releases") or []
            if not mb_releases:
                continue
            titles = [
                (track.get("recording") or {}).get("title") or track.get("title")
                for medium in mb_releases[0].get("media", [])
                for track in medium.get("tracks", [])
            ]
            normalized_mb = {normalize_title(t) for t in titles if t}
            if not normalized_mb:
                continue
            overlap = len(normalized_local & normalized_mb) / len(normalized_local)
            if overlap > best_overlap:
                best_overlap = overlap
                best_rg = rg

        if best_rg is None or best_overlap < _TRACKLIST_OVERLAP_THRESHOLD:
            return None

        release = self._ingest_release_group_json(best_rg)
        if release is None:
            return None
        recording_dtos = await self.get_release_tracks(release.id)
        if not recording_dtos:
            return None
        recordings = [r for r in (self._session.get(Recording, dto.id) for dto in recording_dtos) if r is not None]
        if not recordings:
            return None
        return release, recordings

    # ------------------------------------------------------------------
    # MusicBrainz enrichment doplňovaná líně (jen když chybí) při otevření
    # interpreta/alba, stejný best-effort vzor jako Deezer enrichment níž —
    # pohání "Podle nálady a žánru"/"Česká hudba" domovské sekce.
    # ------------------------------------------------------------------

    async def _enrich_artist_country(self, artist: Artist) -> None:
        if artist.country or not artist.mbid:
            return
        try:
            data = await self._mb.get_artist(artist.mbid)
        except MusicBrainzError:
            return
        country = data.get("country")
        if country:
            artist.country = country
            self._session.add(artist)
            self._session.commit()

    async def _enrich_release_genres(self, release: Release) -> None:
        if release.genres or not release.mbid:
            return
        try:
            data = await self._mb.get_release_group(release.mbid)
        except MusicBrainzError:
            return
        genres = [g["name"] for g in data.get("genres", []) if g.get("name")]
        if genres:
            release.genres = genres
            self._session.add(release)
            self._session.commit()

    # ------------------------------------------------------------------
    # Deezer enrichment — best-effort, nikdy nesmí shodit request na MB datech.
    # ------------------------------------------------------------------

    # Otevření detailu = uživatel na obrázek právě čeká, proto `force=True`
    # (ignoruje "nedávno zkontrolováno" z backfillu). Sdílená logika včetně
    # CAA/Deezer/Wikidata zdrojů a kontroly jmen je v `catalog/artwork.py`.
    async def _enrich_artist_images(self, artist: Artist) -> None:
        if artist.images and "/artist//" not in artist.images[0]:
            return
        self._session.commit()
        if await fill_artist(artist.id, force=True):
            self._session.refresh(artist)

    async def _enrich_release_images(self, release: Release) -> None:
        if release.images:
            return
        self._session.commit()
        if await fill_release(release.id, force=True):
            self._session.refresh(release)

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
