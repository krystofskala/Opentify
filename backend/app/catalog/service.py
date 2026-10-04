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
import json
import logging
import re
import unicodedata
from collections import Counter
from typing import Any
from urllib.parse import quote_plus

from sqlalchemy.dialects.sqlite import insert as sqlite_insert
from sqlalchemy.exc import IntegrityError, OperationalError
from sqlmodel import Session, func, select
from app.catalog.identity import is_own_artist, is_own_id

from app.catalog.artwork import clean_album_title, fill_artist, fill_release
from app.catalog.cache import CACHE_PREFIX
from app.catalog.availability import compute_availability, recording_artist_name, resolve_artist_name
from app.catalog.deezer import DeezerClient
from app.catalog.deezer_ingest import deezer_image, ingest_album, ingest_artist, ingest_track, ingest_track_with_context, norm
from app.catalog.fanart import fill_artist_banner
from app.recommendations.anti_ai_filter import AntiAIFilter
from app.catalog.musicbrainz import MusicBrainzClient, MusicBrainzError
from app.catalog.schemas import ArtistBioOut, ArtistOut, DiscographyOut, ReleaseOut, RecordingOut
from app.catalog.non_music import is_non_music, mark_non_music
from app.catalog.upsert import upsert_artist, upsert_recording, upsert_release
from app.catalog.wikimedia import get_wikimedia_client
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording, Release
from app.redis_bus import get_redis
from app.utils import utcnow

_TRACKLIST_OVERLAP_THRESHOLD = 0.4
_TRACKLIST_CANDIDATE_LIMIT = 3
_PARENS_RE = re.compile(r"\(.*?\)|\[.*?\]")
_NON_ALNUM_RE = re.compile(r"[^a-z0-9]+")

logger = logging.getLogger(__name__)


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

_DEEZER_KIND_FOR_TYPE = {"artist": "artist", "release": "album", "recording": "track"}


def _normalize_query(text: str) -> str:
    """Bez diakritiky, velikosti písmen a interpunkce -- "Vypsaná fiXa" ==
    "vypsana fixa" pro porovnání přesné shody jména interpreta."""
    folded = unicodedata.normalize("NFKD", text).encode("ascii", "ignore").decode().casefold()
    return re.sub(r"[^a-z0-9]+", "", folded)
# Karaoke/"ve stylu"/tribute nahrávky zaplevelují hledání skladeb (živě:
# "nirvana lake of fire" -> 2 karaoke verze v top 4). Pryč, pokud je uživatel
# výslovně nehledá.
_JUNK_TRACK_MARKERS = ("karaoke", "originally performed", "in the style of", "made famous by", "tribute to")
_ANTI_AI = AntiAIFilter()

_MB_PRIMARY_TYPE_TO_RELEASE_TYPE = {
    "album": "album",
    "single": "single",
    "ep": "ep",
}


# Verze, které ve výsledcích jdou až za oficiální studiovou nahrávkou
# (nic se neskrývá -- jen pořadí; kdo hledá "live", dostane je normálně).
_VERSION_RE = re.compile(
    r"\b(live|demo|remix(ed)?|acoustic|akusticky|instrumental|karaoke|cover|session|rehearsal|"
    r"bootleg|unplugged|atmos|edit|version|verze|mix)\b",
    re.IGNORECASE,
)


# "1993-11-08: The Armory, ..." / "1991-09: Club X" / "1989 Live at Y" /
# neúplná data z MB "1994-0x-xx", "1993-06-2x" (bere se jen známá část).
_CONCERT_TITLE_RE = re.compile(r"^(\d{4})(?:-([0-9x?]{1,2}))?(?:-([0-9x?]{1,2}))?(?![0-9a-z])(.*)$", re.IGNORECASE)
# "2008-04-01, evening: ..." / "2008-04-01 (Matinee): ..." / "2000-12-14 PRE-FM: ..."
# (nejvýš 3 slova) -- jen před dvojtečkou.
_CONCERT_QUALIFIER_RE = re.compile(
    r"^(?:\s*,\s*([^:()]+?)|\s*\(([^)]+)\)|\s+([^\s:,()]+(?:\s[^\s:,()]+){0,2}))\s*:(.*)$"
)
_DASHES_RE = re.compile(r"[‐-―−﹘﹣－]")


def parse_concert_title(title: str | None, artist_name: str | None = None) -> tuple[str | None, str | None]:
    """(datum, místo) z názvu bootlegu/živáku. MB píše data s Unicode
    pomlčkami a "x" za neznámé číslice; ponechá se jen známá část
    ("1995-08-xx" -> "1995-08"), upřesnění ("evening", "Matinee") jde za
    místo do závorky. `(None, None)`, když název datem nezačíná."""
    text = _DASHES_RE.sub("-", title or "").strip()
    if artist_name and text.lower().startswith(artist_name.lower() + " "):
        text = text[len(artist_name):].lstrip(" :-,")  # "Radiohead 1995-02-27: ..."
    m = _CONCERT_TITLE_RE.match(text)
    if not m:
        return None, None
    year, month, day, rest = m.groups()
    date = year
    if month and month.isdigit() and len(month) == 2 and 1 <= int(month) <= 12:
        date += f"-{month}"
        if day and day.isdigit() and len(day) == 2 and 1 <= int(day) <= 31:
            date += f"-{day}"
    qualifier = None
    q = _CONCERT_QUALIFIER_RE.match(rest)
    if q:
        qualifier = (q.group(1) or q.group(2) or q.group(3) or "").strip() or None
        rest = q.group(4)
    venue = rest.strip(" \t:;,-–—") or None
    if qualifier:
        venue = f"{venue} ({qualifier})" if venue else qualifier
    return date, venue


_BRACKETS_RE = re.compile(r"[(\[]([^)\]]*)[)\]]")


def _version_part(title: str) -> str:
    """Jen text v závorkách a za " - " ("Song (Live)", "Song - Demo") --
    slovo verze ve vlastním názvu ("Live Forever", "Live Through This")
    verzi neznamená."""
    parts = _BRACKETS_RE.findall(title)
    if " - " in title:
        parts.append(_BRACKETS_RE.sub(" ", title.split(" - ", 1)[1]))
    return " ".join(parts)


def _official_first(results: list[dict], query: str) -> list[dict]:
    """Skladby a alba: oficiální napřed, živé/demo/remix verze za nimi --
    stabilně (jinak pořadí Deezeru). Ostatní typy zůstávají, kde jsou."""
    q = query.lower()

    def demoted(r: dict) -> bool:
        words = {m.group(1).lower() for m in _VERSION_RE.finditer(_version_part(r.get("title") or ""))}
        return any(w not in q for w in words)

    for kind in ("recording", "release"):
        slots = [i for i, r in enumerate(results) if r.get("entityType") == kind]
        ordered = sorted((results[i] for i in slots), key=demoted)  # sorted je stabilní
        for i, r in zip(slots, ordered):
            results[i] = r
    return results


def _canonical_edition(releases: list[dict]) -> dict:
    """Edice pro tracklist: oficiální napřed (promo/bootleg jen když jiná
    není), pak nejméně disků (deluxe s bonusovým / živým diskem nevyhraje
    nad standardní -- živě: Angus & Julia Stone ukazovali studiové skladby
    proložené živými z bonusového disku), obvyklý počet skladeb, nejdřívější
    vydání. Pořadí od MB samo o sobě nic neznamená."""

    def shape(r: dict) -> tuple[int, int]:
        media = [m for m in r.get("media") or [] if m.get("tracks")]
        return len(media), sum(len(m["tracks"]) for m in media)

    # Edice bez skladeb by vyhrály "nejméně disků" (0) -- pryč, jsou-li jiné.
    releases = [r for r in releases if shape(r)[0]] or releases
    official = [r for r in releases if (r.get("status") or "").lower() == "official"]
    releases = official or releases
    fewest = min(shape(r)[0] for r in releases)
    candidates = [r for r in releases if shape(r)[0] == fewest]
    # Nejběžnější počet skladeb mezi nimi (promo/zkrácené edice nevyhrají),
    # pak nejdřívější vydání.
    counts = Counter(shape(r)[1] for r in candidates)
    usual = max(counts, key=lambda n: (counts[n], n))
    return min((r for r in candidates if shape(r)[1] == usual), key=lambda r: r.get("date") or "9999")


def _parse_track_number(raw: str | None) -> int | None:
    if raw is None:
        return None
    try:
        return int(raw)
    except ValueError:
        return None  # vinyl/kazetová strana jako "A1" apod. — bez číselného pořadí



# Prodejci nosičů/streamů, které MusicBrainz občas vede i jako "merch".
_RETAILERS = (
    "cdjapan", "amazon.", "itunes.", "music.apple", "hmv.", "yesasia", "tower.jp", "play-asia",
    "jpopsuki", "ebay.", "walmart.", "target.com", "barnesandnoble", "bol.com", "fnac.", "jpc.de",
    "recordstoreday", "7digital", "qobuz", "beatport", "junodownload", "emp.",
)

def _effective_type(release: Release) -> str:
    """Typ podle skutečného počtu skladeb (viz `_fix_release_type`), jinak podle zdroje."""
    return (release.external_refs or {}).get("typeByTracks") or release.release_type


def _year_of(date: str | None) -> int | None:
    return int(date[:4]) if date and date[:4].isdigit() else None


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
        release = upsert_release(
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
        if "secondary-types" in rg:
            if mark_non_music(release, secondary_types):
                self._session.add(release)
            # Typ vydání z MB (live, demo, remix...) -- živé album bez "live"
            # v názvu ("Stop Making Sense") má stahovat živé verze.
            refs = release.external_refs or {}
            if refs.get("mbSecondary") != secondary_types:
                release.external_refs = {**refs, "mbSecondary": secondary_types}
                self._session.add(release)
                self._session.commit()
        return release

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
            # Zástupná `own:` id (vlastní interpret) klient nevidí.
            mbid=_real_id(artist.mbid),
            deezer_id=_real_id(artist.deezer_id),
            name=artist.name,
            sort_name=artist.sort_name,
            images=artist.images,
            banner_url=(artist.external_refs or {}).get("bannerUrl"),
        )

    def _to_release_out(self, release: Release) -> ReleaseOut:
        return ReleaseOut(
            id=release.id,
            mbid=_real_id(release.mbid),
            artist_id=release.artist_id,
            title=release.title,
            release_date=release.release_date,
            release_type=_effective_type(release),
            images=release.images,
            notes=(release.external_refs or {}).get("notes"),
            imported=(release.external_refs or {}).get("source") in ("youtube", "soundcloud", "manual"),
            youtube_only=(release.external_refs or {}).get("source") in ("youtube", "soundcloud"),
            credits=(release.external_refs or {}).get("credits"),
            genres=release.genres or [],
        )

    def _to_recording_out(self, recording: Recording) -> RecordingOut:
        return RecordingOut(
            id=recording.id,
            mbid=_real_id(recording.mbid),
            release_id=recording.release_id,
            artist_id=recording.artist_id,
            artist_name=recording_artist_name(self._session, recording),
            title=recording.title,
            duration_ms=recording.duration_ms,
            isrc=_real_id(recording.isrc),
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
        """Deezer (rychlý, velkorysý limit) -- MusicBrainz jen jako záloha,
        když Deezer úplně selže. Dřív šlo všechno přes MusicBrainz (1 req/s):
        klient při psaní posílá 3 typy dotazů na každé písmeno, fronta
        rostla a hledání vracelo 503 / "nic se nenačítá" (živě)."""
        types_to_query = [entity_type] if entity_type else list(_MB_ENTITY_FOR_TYPE)
        fetched = await asyncio.gather(
            *(self._dz.search_typed(_DEEZER_KIND_FOR_TYPE[t], query, limit, offset) for t in types_to_query)
        )
        # Vlastní hudba (tátův Kontrast) online není -- z DB, a navrch.
        own = self._own_matches(query, types_to_query) if offset == 0 else []
        if all(data is None for data in fetched):
            found = await self._search_musicbrainz(query, entity_type, limit, offset)
            found["results"] = own + found.get("results", [])
            return found

        # Upsert až po všech `await`ech a bez dalších -- viz deezer_ingest
        # (souběžná hledání se tu nemůžou proložit a zdvojit řádky).
        # Do DB se zapisuje jen napoprvé: id našich řádků k výsledku Deezeru
        # se pamatují (stejné TTL jako Deezer cache) a další stejné hledání
        # (klient posílá dotaz na každé písmeno) už jen čte.
        remembered = await asyncio.gather(*(self._search_ids_get(t, query, limit, offset) for t in types_to_query))
        results: list[dict[str, Any]] = []
        seen_artists: set[str] = {r["id"] for r in own if r.get("entityType") == "artist"}
        to_remember: dict[str, list[str]] = {}
        for t, data, ids in zip(types_to_query, fetched, remembered):
            from_ids = self._search_results_from_ids(t, ids, seen_artists) if ids is not None else None
            if from_ids is not None:
                results.extend(from_ids)
                continue
            type_ids: list[str] = []
            if t == "artist" and data:
                # Deezer řadí interprety zvláštně (živě: "nirvana" -> nejdřív
                # "Nirvana (UK)" s 237 fanoušky, pak Nirvana s 10 miliony).
                # Přesná shoda jména napřed, pak podle počtu fanoušků.
                wanted = _normalize_query(query)
                data = sorted(
                    data,
                    key=lambda a: (_normalize_query(a.get("name") or "") != wanted, -(a.get("nb_fan") or 0)),
                )
            for item in data or []:
                if t == "artist":
                    artist = ingest_artist(self._session, item)
                    # Víc Deezer profilů téhož interpreta -> jeden výsledek.
                    if artist is not None and artist.id not in seen_artists:
                        seen_artists.add(artist.id)
                        type_ids.append(artist.id)
                        results.append({"entityType": "artist", **self._to_artist_out(artist).model_dump(by_alias=True)})
                elif t == "release":
                    artist = ingest_artist(self._session, item.get("artist") or {})
                    release = ingest_album(self._session, item, artist) if artist else None
                    if release is not None:
                        type_ids.append(release.id)
                        results.append({"entityType": "release", **self._to_release_out(release).model_dump(by_alias=True)})
                else:
                    if _ANTI_AI.is_blocked_text((item.get("artist") or {}).get("name"), item.get("title")):
                        continue
                    title_lower = (item.get("title") or "").lower()
                    if any(m in title_lower and m not in query.lower() for m in _JUNK_TRACK_MARKERS):
                        continue
                    recording = ingest_track_with_context(self._session, item)
                    if recording is not None:
                        type_ids.append(recording.id)
                        results.append(
                            {"entityType": "recording", **self._to_recording_out(recording).model_dump(by_alias=True)}
                        )
            if data is not None:
                to_remember[t] = type_ids
        self._session.commit()
        for t, type_ids in to_remember.items():
            await self._search_ids_set(t, query, limit, offset, type_ids)
        results = await self._merge_verified_duplicates(results)
        results = _official_first(results, query)
        results = own + results
        return {"query": query, "total": len(results), "results": results[: limit or len(results)]}

    @staticmethod
    def _search_ids_key(t: str, query: str, limit: int, offset: int) -> str:
        return f"{CACHE_PREFIX}search:ids:v1:{t}:{query}:{limit}:{offset}"

    async def _search_ids_get(self, t: str, query: str, limit: int, offset: int) -> list[str] | None:
        try:
            raw = await get_redis().get(self._search_ids_key(t, query, limit, offset))
        except Exception:  # noqa: BLE001 - bez Redisu prostě zapsat jako dřív
            return None
        return json.loads(raw) if raw is not None else None

    async def _search_ids_set(self, t: str, query: str, limit: int, offset: int, ids: list[str]) -> None:
        from app.catalog.deezer import SEARCH_TTL_SECONDS

        try:
            await get_redis().set(self._search_ids_key(t, query, limit, offset), json.dumps(ids), ex=SEARCH_TTL_SECONDS)
        except Exception:  # noqa: BLE001
            pass

    def _search_results_from_ids(self, t: str, ids: list[str], seen_artists: set[str]) -> list[dict[str, Any]] | None:
        """Výsledky z už zapsaných řádků (jen čtení). Chybí-li některý řádek
        (mezitím sloučený/smazaný), `None` -> zapsat znovu z Deezeru."""
        model = {"artist": Artist, "release": Release}.get(t, Recording)
        rows = [self._session.get(model, i) for i in ids]
        if any(r is None or (r.external_refs or {}).get("mergedInto") for r in rows):
            return None
        out: list[dict[str, Any]] = []
        for row in rows:
            if t == "artist":
                if row.id in seen_artists:
                    continue
                seen_artists.add(row.id)
                out.append({"entityType": "artist", **self._to_artist_out(row).model_dump(by_alias=True)})
            elif t == "release":
                out.append({"entityType": "release", **self._to_release_out(row).model_dump(by_alias=True)})
            else:
                out.append({"entityType": "recording", **self._to_recording_out(row).model_dump(by_alias=True)})
        return out

    async def _merge_verified_duplicates(self, results: list[dict[str, Any]]) -> list[dict[str, Any]]:
        """Deezer má jednoho interpreta občas víckrát (živě: Lana Del Rey 3×,
        různá id, stejná fotka). Sloučit jen OVĚŘENĚ: stejné jméno, stejná
        fotka A společná alba -- fake profil se stejnou fotkou zůstane zvlášť."""
        from app.catalog.deezer_ingest import is_placeholder_picture

        out: list[dict[str, Any]] = []
        seen: set[str] = set()
        for item in results:
            if item.get("entityType") != "artist":
                out.append(item)
                continue
            artist = self._session.get(Artist, item["id"])
            image = (artist.images or [None])[0] if artist else None
            canonical = None
            if artist is not None and image and not is_placeholder_picture(image) and artist.deezer_id:
                others = [
                    a
                    for a in self._session.exec(select(Artist).where(func.lower(Artist.name) == artist.name.lower())).all()
                    if a.id != artist.id
                    and not (a.external_refs or {}).get("mergedInto")
                    and a.images
                    and a.images[0] == image
                ]
                others.sort(key=lambda a: (a.mbid is None, a.id))
                for other in others:
                    if await self._same_discography(artist, other):
                        canonical = self._merge_artist_into(artist, other)
                        self._session.commit()
                        break
            target = canonical or artist
            if target is None or target.id in seen:
                continue
            seen.add(target.id)
            out.append({"entityType": "artist", **self._to_artist_out(target).model_dump(by_alias=True)} if canonical else item)
        return out

    async def _same_discography(self, candidate: Artist, other: Artist) -> bool:
        """Aspoň jedno album (normalizovaný název) Deezer profilu `candidate`
        je i v diskografii `other` -- ověření, že jde o téhož interpreta."""
        albums = await self._dz.artist_albums(candidate.deezer_id) if candidate.deezer_id else None
        theirs = {norm(clean_album_title(a.get("title") or "")) for a in albums or []} - {""}
        if not theirs:
            return False
        ours = {
            norm(clean_album_title(r.title))
            for r in self._session.exec(select(Release).where(Release.artist_id == other.id)).all()
        }
        if other.deezer_id and not ours:
            other_albums = await self._dz.artist_albums(other.deezer_id) or []
            ours = {norm(clean_album_title(a.get("title") or "")) for a in other_albums}
        return bool(theirs & ours)

    def _own_matches(self, query: str, types: list[str]) -> list[dict[str, Any]]:
        """Vlastní interpreti/alba/skladby (`own:` id), jejichž název obsahuje
        hledaný text -- bez diakritiky a velikosti písmen."""
        wanted = norm(query)
        if len(wanted) < 2:
            return []
        out: list[dict[str, Any]] = []
        own = (Artist.mbid >= "own:") & (Artist.mbid < "own;")  # type: ignore[union-attr]
        if "artist" in types:
            for artist in self._session.exec(select(Artist).where(own)).all():
                if wanted in norm(artist.name):
                    out.append({"entityType": "artist", **self._to_artist_out(artist).model_dump(by_alias=True)})
        if "release" in types:
            for release in self._session.exec(select(Release).where((Release.mbid >= "own:") & (Release.mbid < "own;"))).all():  # type: ignore[union-attr]
                artist = self._session.get(Artist, release.artist_id)
                if wanted in norm(release.title) or (artist and wanted in norm(artist.name)):
                    out.append({"entityType": "release", **self._to_release_out(release).model_dump(by_alias=True)})
        if "recording" in types:
            for rec in self._session.exec(select(Recording).where((Recording.mbid >= "own:") & (Recording.mbid < "own;"))).all():  # type: ignore[union-attr]
                if wanted in norm(rec.title):
                    out.append({"entityType": "recording", **self._to_recording_out(rec).model_dump(by_alias=True)})
        return out

    async def _search_musicbrainz(
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
        artist = self._get_artist_row(artist_id)
        if artist is None:
            return None
        artist = await self._resolve_artist_mbid_lazily(artist)
        await self._enrich_artist_images(artist)
        await self._enrich_artist_country(artist)
        self._session.commit()
        if await fill_artist_banner(artist.id):
            self._session.refresh(artist)
        return self._to_artist_out(artist)

    # v2: řádky zkontrolované dřívější verzí (která při kolizi MBID jen
    # skončila) se tak jednou projdou znovu a sloučí.
    _MB_LOOKUP_KEY = "mbLookupAt2"
    _MERGED_INTO_KEY = "mergedInto"

    def _get_artist_row(self, artist_id: str) -> Artist | None:
        """Řádek interpreta, sledující sloučení (Deezer duplikát -> kanonický
        řádek s MBID). Klient mohl mít otevřené staré id -- dál funguje."""
        artist = self._session.get(Artist, artist_id)
        for _ in range(3):
            target = (artist.external_refs or {}).get(self._MERGED_INTO_KEY) if artist else None
            if not target:
                break
            artist = self._session.get(Artist, target) or artist
        return artist

    async def _resolve_artist_mbid_lazily(self, artist: Artist) -> Artist:
        """Interpret založený z Deezer hledání nemá MBID -- ten je potřeba
        pro životopis, nevydaný materiál, podobné interprety a fanart.tv
        banner. Dohledá se jednou, při otevření detailu (1 MusicBrainz dotaz).
        Jen jistá shoda (přesné jméno, skóre >= 90). Když už stejné MBID má
        jiný řádek (typicky interpret z knihovny), je to duplicita -- tenhle
        řádek se do něj sloučí (Deezer id, alba, skladby) a vrátí se ten
        kanonický; dřív tu hledání jen skončilo a Deezer verze interpreta
        zůstala navždy bez MBID (živě: The Beatles bez životopisu/rarit)."""
        if artist.mbid is not None or (artist.external_refs or {}).get(self._MB_LOOKUP_KEY):
            return artist
        artist.external_refs = {**(artist.external_refs or {}), self._MB_LOOKUP_KEY: utcnow().isoformat()}
        self._session.add(artist)
        try:
            data = await self._mb.search("artist", f'artist:"{artist.name}"', 5, 0)
        except MusicBrainzError:
            self._session.commit()
            return artist
        wanted = norm(artist.name)
        for candidate in data.get("artists", []):
            if norm(candidate.get("name")) != wanted or int(candidate.get("score") or 0) < 90:
                continue
            mbid = candidate.get("id")
            if not mbid:
                break
            existing = self._session.exec(select(Artist).where(Artist.mbid == mbid)).first()
            if existing is None:
                artist.mbid = mbid
                artist.sort_name = candidate.get("sort-name") or artist.sort_name
            elif existing.id != artist.id:
                artist = self._merge_artist_into(artist, existing)
            break
        self._session.commit()
        return artist

    def _merge_artist_into(self, duplicate: Artist, canonical: Artist) -> Artist:
        if duplicate.id == canonical.id:
            return canonical
        for model in (Release, Recording):
            for row in self._session.exec(select(model).where(model.artist_id == duplicate.id)).all():
                row.artist_id = canonical.id
                self._session.add(row)
        if not canonical.deezer_id:
            canonical.deezer_id = duplicate.deezer_id
        if not canonical.images and duplicate.images:
            canonical.images = duplicate.images
        # Deezer id si duplikát NECHÁ -- je to alias: další hledání ho najde
        # a přes `mergedInto` skončí u hlavního řádku. Dřív se mazalo a příští
        # hledání založilo nový řádek (živě: Lana Del Rey 3×).
        duplicate.external_refs = {**(duplicate.external_refs or {}), self._MERGED_INTO_KEY: canonical.id}
        self._session.add(duplicate)
        self._session.add(canonical)
        return canonical

    async def _resolve_deezer_id_lazily(self, artist: Artist) -> None:
        """Interpret bez MBID i bez Deezer id (přišel z ListenBrainz/lokální
        knihovny a MusicBrainz ho nezná) neměl odkud vzít diskografii --
        stránka ukazovala "0 vydání" (živě: Hector Gachan). Deezer id se
        dohledá podle přesného jména (nejvíc fanoušků při shodě)."""
        if artist.deezer_id:
            return
        try:
            candidates = await self._dz.search_artist(artist.name, limit=5)
        except Exception:  # noqa: BLE001 - best-effort
            return
        wanted = norm(artist.name)
        matches = [c for c in candidates if norm(c.get("name")) == wanted and c.get("id")]
        if not matches:
            return
        from app.catalog.identity import local_only_artist, verified_deezer_artist

        if local_only_artist(artist.name) is not None:
            # Vlastní hudba: jen ověřený kandidát (shodné album), ne podle jména.
            best = await verified_deezer_artist(artist, matches)
            if best is None:
                return
        else:
            best = max(matches, key=lambda c: c.get("nb_fan") or 0)
        deezer_id = str(best["id"])
        owner = self._session.exec(select(Artist).where(Artist.deezer_id == deezer_id)).first()
        if owner is not None and owner.id != artist.id:
            return  # jiný řádek už tohle id má -- nesahat, sloučení řeší MBID cesta
        artist.deezer_id = deezer_id
        self._session.add(artist)
        self._session.commit()

    def _youtube_releases(self, artist: Artist) -> list[Release]:
        """Vydání naimportovaná z YouTube odkazu (neoficiální alba, koncerty)."""
        return [
            r
            for r in self._session.exec(select(Release).where(Release.artist_id == artist.id)).all()
            # "manual" = album ručně přiřazené k interpretovi (MB ho vede u
            # stejnojmenného cizího, viz No Phun Intended u Tylera Josepha).
            if (r.external_refs or {}).get("source") in ("youtube", "soundcloud", "manual")
        ]

    async def _deezer_discography(self, artist: Artist) -> list[Release]:
        await self._resolve_deezer_id_lazily(artist)
        albums = await self._dz.artist_albums(artist.deezer_id) if artist.deezer_id else None
        # Deezer občas slučuje stejnojmenné interprety do jednoho (živě: česká
        # Marsyas + francouzské duo) -- alba označená "nepatří sem" vynechat.
        not_mine = set((artist.external_refs or {}).get("notMine") or [])
        albums = [a for a in albums or [] if str(a.get("id")) not in not_mine]
        releases = [r for r in (ingest_album(self._session, a, artist) for a in albums) if r is not None]
        self._session.commit()
        return releases

    async def get_discography(
        self, artist_id: str, release_type: str | None
    ) -> DiscographyOut | None:
        artist = self._get_artist_row(artist_id)
        if artist is None:
            return None
        if (artist.mbid or "").startswith("own:"):
            # Vlastní interpret (tátův Kontrast): jen jeho alba z vlastních
            # souborů, nikde online se nehledá (app/catalog/identity.py).
            releases = list(self._session.exec(select(Release).where(Release.artist_id == artist.id)).all())
            if release_type:
                releases = [r for r in releases if _effective_type(r) == release_type]
            releases.sort(key=lambda r: r.release_date or "9999")
            return DiscographyOut(artist=self._to_artist_out(artist), releases=[self._to_release_out(r) for r in releases])
        if artist.mbid is None:
            # Interpret jen z Deezeru (hledání/žebříček) -- diskografie odtud.
            releases = await self._deezer_discography(artist) + self._youtube_releases(artist)
            releases = [r for r in releases if not is_non_music(r)]
            if release_type:
                releases = [r for r in releases if _effective_type(r) == release_type]
            releases.sort(key=lambda r: r.release_date or "9999")
            return DiscographyOut(artist=self._to_artist_out(artist), releases=[self._to_release_out(r) for r in releases])

        # Jen skupiny s aspoň jedním OFICIÁLNÍM vydáním (MB search `status:`).
        # Dřív browse vracel prvních 100 skupin bez ohledu na status -- u velkých
        # interpretů (The Beatles: ~2000 skupin, stovky bootlegů) tak bootlegy
        # vytlačily oficiální alba. Neoficiální materiál má vlastní sekci,
        # viz `get_rarities`.
        groups = await self._search_release_groups(artist.mbid, self._official_query(artist.mbid, release_type), 300)
        if groups is None:
            try:
                data = await self._mb.browse_release_groups(artist.mbid, release_type, limit=100, offset=0)
            except MusicBrainzError:
                data = {}
            groups = data.get("release-groups", [])

        releases: list[Release] = []
        for rg in groups:
            # Browse (na rozdíl od search) nevrací `artist-credit` -- interpret
            # je jistý z kontextu dotazu, doplníme ho manuálně.
            rg_with_artist = {
                **rg,
                "artist-credit": [{"artist": {"id": artist.mbid, "name": artist.name, "sort-name": artist.sort_name}}],
            }
            release = self._ingest_release_group_json(rg_with_artist)
            if release is not None:
                if rg.get("artist-credit"):  # search ho nese -- spolupráce (Thile & Daves)
                    self._store_credits(release, rg["artist-credit"])
                releases.append(release)

        # MusicBrainz má u menších interpretů mezery (živě: Hector Gachan --
        # MB 2 alba, Deezer 17 vydání vč. 14 singlů). Doplníme z Deezeru to,
        # co v MB chybí; shoda podle normalizovaného názvu, ať se alba
        # nezdvojí ("Untitled '91" z MB i z Deezeru = jedno).
        try:
            deezer_releases = await self._deezer_discography(artist)
        except Exception:  # noqa: BLE001 - doplněk, nesmí shodit diskografii
            deezer_releases = []
        # Rozhovory/mluvené slovo pryč -- ale jejich názvy zůstanou "známé",
        # ať se nevrátí deezerovou kopií (Deezer je vede jako běžné album).
        non_music_titles = {norm(r.title) for r in releases if is_non_music(r)}
        releases = [r for r in releases if not is_non_music(r)]
        deezer_releases = [r for r in deezer_releases if not is_non_music(r)]
        # Stejný název = totéž album, jen když sedí i rok (± 1). Vydání
        # s jiným rokem je reedice / nová nahrávka -- ukázat ho (živě:
        # Texican Badman 2019 s jinou "Sweet Melinda" se schovávalo za 1981).
        known: dict[str, list[int | None]] = {}
        for r in releases:
            known.setdefault(norm(r.title), []).append(_year_of(r.release_date))
        ids = {r.id for r in releases}
        for extra in deezer_releases:
            if release_type and _effective_type(extra) != release_type:
                continue
            key, year = norm(extra.title), _year_of(extra.release_date)
            if key in non_music_titles or extra.id in ids:
                continue
            if key in known and any(y is None or year is None or abs(y - year) <= 1 for y in known[key]):
                continue
            known.setdefault(key, []).append(year)
            ids.add(extra.id)
            releases.append(extra)

        # Alba jen z YouTube (import odkazu jako album/koncert interpreta).
        known_ids = {r.id for r in releases}
        releases += [r for r in self._youtube_releases(artist) if r.id not in known_ids]

        not_mine = set((artist.external_refs or {}).get("notMine") or [])
        releases = [r for r in releases if r.id not in not_mine and (r.deezer_id or "") not in not_mine]
        if release_type:
            releases = [r for r in releases if _effective_type(r) == release_type]
        releases.sort(key=lambda r: r.release_date or "9999")
        return DiscographyOut(
            artist=self._to_artist_out(artist),
            releases=[self._to_release_out(r) for r in releases],
        )

    @staticmethod
    def _official_query(artist_mbid: str, release_type: str | None) -> str:
        query = f"arid:{artist_mbid} AND status:official"
        if release_type == "compilation":
            query += " AND secondarytype:compilation"
        elif release_type:
            query += f" AND primarytype:{release_type}"
        return query

    async def _search_release_groups(self, artist_mbid: str, query: str, max_items: int) -> list[dict[str, Any]] | None:
        """MB release-group search po stránkách po 100; `None` při chybě MB
        (volající pak spadne na starší browse)."""
        groups: list[dict[str, Any]] = []
        offset = 0
        try:
            while offset < max_items:
                data = await self._mb.search("release-group", query, 100, offset)
                page = data.get("release-groups") or []
                groups.extend(page)
                if len(page) < 100 or len(groups) >= (data.get("count") or 0):
                    break
                offset += 100
        except MusicBrainzError:
            return None if not groups else groups
        # Search na rozdíl od browse vrací i skupiny, kde je interpret jen
        # jedním z více -- necháme jen ty, kde ho MB uvádí jako interpreta.
        # Stránkování searche se při změnách v MB překrývá -> bez duplicit.
        seen: set[str] = set()
        out = []
        for g in groups:
            if g.get("id") in seen:
                continue
            seen.add(g.get("id"))
            if any((c.get("artist") or {}).get("id") == artist_mbid for c in g.get("artist-credit") or []):
                out.append(g)
        return out

    _RARITY_ORDER = {"demo": 0, "live": 1, "bootleg": 2}

    async def get_concerts(self, artist_id: str) -> list[dict[str, Any]] | None:
        """Koncertní archiv interpreta: oficiální živá alba + živáky a
        bootlegy z MusicBrainz, chronologicky, s datem a místem z názvu
        ("1993-11-08: The Armory, Philadelphia" -- tak MB bootlegy pojmenovává)."""
        rarities = await self.get_rarities(artist_id, limit=1000)
        if rarities is None:
            return None
        items: list[tuple[ReleaseOut, bool]] = []
        seen: set[str] = set()
        for r in rarities:
            if r.rarity in ("live", "bootleg") and r.id not in seen:
                seen.add(r.id)
                items.append((r, False))
        for rel in self._session.exec(select(Release).where(Release.artist_id == artist_id)).all():
            secondary = [t.lower() for t in (rel.external_refs or {}).get("mbSecondary") or []]
            if "live" in secondary and rel.id not in seen:
                seen.add(rel.id)
                items.append((self._to_release_out(rel), True))
        artist = self._get_artist_row(artist_id)
        out = []
        for release, official in items:
            date, venue = parse_concert_title(release.title, artist.name if artist else None)
            if date is None:
                date = str(release.release_date) if release.release_date else None
            out.append({
                **release.model_dump(by_alias=True),
                "concertDate": date,
                "venue": venue,
                "official": official,
            })
        out.sort(key=lambda x: x["concertDate"] or "9999")
        return out

    async def get_rarities(self, artist_id: str, limit: int = 150) -> list[ReleaseOut] | None:
        """Nevydaný/vzácný materiál: dema, živáky a bootlegy -- skupiny z
        MusicBrainz, které NEMAJÍ žádné oficiální vydání. Přehrávají se stejně
        jako cokoliv jiného (obstarání přes Soulseek/YouTube na požádání),
        takže se ukáže jen to, co MB zná; jestli je skladba reálně k sehnání,
        se ukáže až při přehrání."""
        artist = self._get_artist_row(artist_id)
        if artist is None:
            return None
        if artist.mbid is None:
            return []
        query = (
            f"arid:{artist.mbid} AND (secondarytype:demo OR secondarytype:live OR "
            'status:bootleg OR status:promotion OR status:"pseudo-release")'
        )
        groups = await self._search_release_groups(artist.mbid, query, 300) or []

        out: list[ReleaseOut] = []
        seen: set[str] = set()  # dvě MB skupiny můžou vést na jeden náš řádek
        for rg in groups:
            statuses = {(r.get("status") or "").lower() for r in rg.get("releases") or []}
            if "official" in statuses:
                continue  # oficiálně vydané -- patří do běžné diskografie
            secondary = {t.lower() for t in rg.get("secondary-types") or []}
            if secondary & {"interview", "spokenword", "audiobook", "audio drama"}:
                continue
            rarity = "demo" if "demo" in secondary else "live" if "live" in secondary else "bootleg"
            release = self._ingest_release_group_json(
                {**rg, "artist-credit": [{"artist": {"id": artist.mbid, "name": artist.name, "sort-name": artist.sort_name}}]}
            )
            if release is not None and release.id not in seen:
                seen.add(release.id)
                if (release.external_refs or {}).get("rarity") != rarity:
                    # Worker podle toho chce u stahování živou / demo verzi
                    # (worker._version_hint), ne studiovou.
                    release.external_refs = {**(release.external_refs or {}), "rarity": rarity}
                    self._session.add(release)
                out.append(self._to_release_out(release).model_copy(update={"rarity": rarity}))
        self._session.commit()
        out.sort(key=lambda r: (self._RARITY_ORDER[r.rarity or "bootleg"], r.release_date or "9999"))
        return out[:limit]

    async def get_artist_bio(self, artist_id: str) -> ArtistBioOut | None:
        """Životopis + "Podobní interpreti" pro `ArtistScreen` -- MusicBrainz
        strukturu nemá přímo, jen odkazy (`relations`, viz rozšířený `inc` v
        `MusicBrainzClient.get_artist`). Wikidata/Wikipedia dotaz je
        best-effort stejně jako Deezer enrichment výš -- chybějící životopis
        nebo přerušené externí API nikdy nesmí shodit celou obrazovku
        interpreta, jen se `bio` vrátí `None`."""
        artist = self._get_artist_row(artist_id)
        if artist is None:
            return None
        if (artist.mbid or "").startswith("own:"):
            # Vlastní interpret: vlastní text a ručně zadané kapely
            # (`external_refs.bands` = id našich interpretů), nic online.
            refs = artist.external_refs or {}
            bands = [a for a in (self._session.get(Artist, i) for i in refs.get("bands") or []) if a is not None]
            return ArtistBioOut(
                bio=refs.get("bio"), related_artists=[], bands=[self._to_artist_out(a) for a in bands]
            )
        # "Podobní" z Last.fm (podobnost podle posluchačů) -- MusicBrainz
        # vztahy (členové, spolupráce) jsou jen záloha.
        similar = await self._lastfm_similar(artist)
        if artist.mbid is None:
            return ArtistBioOut(bio=None, related_artists=[self._to_artist_out(a) for a in similar])

        try:
            data = await self._mb.get_artist(artist.mbid)
        except MusicBrainzError:
            return ArtistBioOut(bio=None, related_artists=[self._to_artist_out(a) for a in similar])

        relations = data.get("relations") or []

        bio: str | None = None
        wikidata_qid = self._extract_wikidata_qid(relations)
        if wikidata_qid is not None:
            wiki = get_wikimedia_client()
            bio = await wiki.get_bio_from_wikidata(wikidata_qid)

        related = similar or self._upsert_related_artists(relations)
        bands, members = self._band_relations(relations)
        self._session.commit()
        return ArtistBioOut(
            bio=bio,
            related_artists=[self._to_artist_out(a) for a in related if a.id not in {b.id for b in bands + members}],
            bands=[self._to_artist_out(a) for a in bands],
            members=[self._to_artist_out(a) for a in members],
        )

    def _band_relations(self, relations: list[dict[str, Any]]) -> tuple[list[Artist], list[Artist]]:
        """MusicBrainz "member of band": `forward` = tenhle člověk je členem
        kapely (-> kapely a projekty), `backward` = člen téhle kapely (->
        členové, současní napřed). Vlastní interpret s `external_refs.mbidAlias`
        nahradí stejného člověka z MusicBrainz (Tyler Joseph u Pilotů vede na
        jeho vlastní profil)."""
        aliases: dict[str, Artist] = {}
        for own in self._session.exec(select(Artist).where((Artist.mbid >= "own:") & (Artist.mbid < "own;"))).all():  # type: ignore[union-attr]
            alias = (own.external_refs or {}).get("mbidAlias")
            if alias:
                aliases[alias] = own

        bands: list[Artist] = []
        current: list[Artist] = []
        former: list[Artist] = []
        seen: set[str] = set()
        for rel in relations:
            if rel.get("type") != "member of band" or rel.get("target-type") != "artist":
                continue
            stub = rel.get("artist") or {}
            mbid, name = stub.get("id"), stub.get("name")
            if not mbid or not name or mbid in seen:
                continue
            seen.add(mbid)
            row = aliases.get(mbid) or upsert_artist(
                self._session, mbid=mbid, name=name, sort_name=stub.get("sort-name")
            )
            if rel.get("direction") == "forward":
                bands.append(row)
            elif rel.get("ended"):
                former.append(row)
            else:
                current.append(row)
        return bands[:12], (current + former)[:12]

    _SIMILAR_LIMIT = 12

    async def _lastfm_similar(self, artist: Artist) -> list[Artist]:
        from app.catalog import lastfm

        found = await lastfm.similar_artists(artist.name, limit=self._SIMILAR_LIMIT * 2)
        # Deezer hledání souběžně (dřív jedno po druhém -- studená stránka 3 s).
        sem = asyncio.Semaphore(5)

        async def look(name: str) -> dict[str, Any] | None:
            async with sem:
                try:
                    hits = await self._dz.search_artist(name)
                except Exception:  # noqa: BLE001
                    return None
            return next((h for h in hits if norm(h.get("name") or "") == norm(name)), None)

        dz_hits = await asyncio.gather(*(look(item["name"]) for item in found))
        out: list[Artist] = []
        seen: set[str] = {artist.id}
        for item, hit in zip(found, dz_hits):
            row: Artist | None = None
            if item.get("mbid"):
                row = self._session.exec(select(Artist).where(Artist.mbid == item["mbid"])).first()
            if row is None:
                # Přes Deezer (fotka, diskografie), jen přesná shoda jména.
                if hit is not None:
                    row = ingest_artist(self._session, hit)
            if row is None and item.get("mbid"):
                row = upsert_artist(self._session, mbid=item["mbid"], name=item["name"], sort_name=None)
            if row is None or row.id in seen:
                continue
            seen.add(row.id)
            out.append(row)
            if len(out) >= self._SIMILAR_LIMIT:
                break
        if out:
            self._session.commit()
        return out

    async def get_artist_support(self, artist_id: str) -> dict[str, Any] | None:
        """Jak interpreta podpořit (sekce "Podpořit" na jeho stránce): odkazy
        z MusicBrainz `url-rels` (web, Bandcamp, obchod, Discogs, koncerty).
        Co MusicBrainz nemá, doplní odkaz na vyhledávání (Discogs, Songkick,
        Bandcamp) -- ať sekce není prázdná. Jen odkazy; nic se nestahuje,
        otevírá je až uživatel klepnutím."""
        artist = self._get_artist_row(artist_id)
        if artist is None:
            return None
        relations: list[dict[str, Any]] = []
        # Vlastní interpret: hledání podle jména by vedlo na cizí kapelu.
        own = is_own_artist(artist)
        if artist.mbid and not own:
            try:
                relations = (await self._mb.get_artist(artist.mbid)).get("relations") or []
            except MusicBrainzError:
                relations = []
        by_type: dict[str, list[str]] = {}
        for rel in relations:
            url = (rel.get("url") or {}).get("resource")
            if url and not rel.get("ended"):
                by_type.setdefault(str(rel.get("type") or ""), []).append(url)

        def first(*types: str) -> str | None:
            for t in types:
                for url in by_type.get(t, []):
                    return url
            return None

        name = quote_plus(artist.name)
        concerts = first("bandsintown", "songkick")
        # Jen skutečný merch interpreta. "purchase for mail-order" jsou na
        # MusicBrainz obchody s nosiči (CDJapan, Amazon...) -- ne obchod
        # kapely (živě: Twenty One Pilots -> CDJapan s blokací přístupu).
        shops = [
            url
            for t in ("merchandise", "online merchandise")
            for url in by_type.get(t, [])
            if not any(r in url.lower() for r in _RETAILERS)
        ]
        # Oficiální obchod ("shop."/"store."/"merch") před ostatními.
        shops.sort(key=lambda u: 0 if any(k in u.lower() for k in ("shop", "store", "merch")) else 1)
        shop = shops[0] if shops else None
        return {
            "web": first("official homepage"),
            "bandcamp": first("bandcamp") or None,
            "bandcampSearch": None if own else f"https://bandcamp.com/search?q={name}&item_type=b",
            "shop": shop,
            "records": first("discogs") or (None if own else f"https://www.discogs.com/search/?q={name}&type=artist"),
            "concerts": concerts or (None if own else f"https://www.songkick.com/search?query={name}"),
            "concertsSource": (
                "Bandsintown" if concerts and "bandsintown" in concerts else "Songkick"
            ),
        }

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
        await self._enrich_release_credits(release)
        await self._enrich_release_date(release)
        return self._to_release_out(release)

    async def search_collabs(self, query: str) -> dict[str, Any]:
        """Viz app/catalog/collabs.py -- výsledky převzaté do katalogu."""
        from app.catalog import collabs

        empty: dict[str, Any] = {"artists": [], "recordings": [], "releases": [], "versions": None}
        try:
            versions = await collabs.artist_versions(self._dz, query)
        except Exception:  # noqa: BLE001
            logger.exception("hledání verzí selhalo: %s", query)
            versions = None
        versions_out = None
        if versions is not None:
            v_artist, v_title, v_tracks = versions
            recs = []
            for t in v_tracks:
                r = ingest_track_with_context(self._session, t)
                if r is None:
                    continue
                recs.append(r)
            self._session.commit()
            versions_out = {
                "artistName": v_artist.get("name"),
                "title": v_title,
                "recordings": [self._to_recording_out(r).model_dump(by_alias=True) for r in recs],
            }
            empty = {**empty, "versions": versions_out}
        try:
            pair = await collabs.resolve_pair(self._dz, query)
            if pair is None:
                return empty
            found = await collabs.find(self._dz, *pair)
        except Exception:  # noqa: BLE001 -- doplněk hledání, nesmí ho shodit
            logger.exception("hledání spoluprací selhalo: %s", query)
            return empty
        if not found["tracks"] and not found["albums"]:
            return empty
        artists = [ingest_artist(self._session, a) for a in pair]
        recordings = [r for r in (ingest_track_with_context(self._session, t) for t in found["tracks"]) if r is not None]
        releases = []
        for al in found["albums"]:
            owner = ingest_artist(self._session, al.get("artist") or {}) if al.get("artist") else None
            if owner is not None:
                rel = ingest_album(self._session, al, owner)
                if rel is not None:
                    releases.append(rel)
        self._session.commit()
        return {
            "artists": [self._to_artist_out(a).model_dump(by_alias=True) for a in artists if a is not None],
            "recordings": [self._to_recording_out(r).model_dump(by_alias=True) for r in recordings],
            "releases": [self._to_release_out(r).model_dump(by_alias=True) for r in releases],
            "versions": versions_out,
        }

    async def get_release_credits(self, release_id: str) -> dict[str, Any] | None:
        """Obsazení alba (viz app/catalog/credits.py) z kanonické edice MB.
        Vlastní / importované album a album jen z Deezeru: prázdné."""
        from app.catalog.credits import album_credits

        release = self._session.get(Release, release_id)
        if release is None:
            return None
        empty = {"musicians": [], "writers": [], "production": [], "tracks": 0}
        if not release.mbid or is_own_id(release.mbid):
            return empty
        try:
            data = await self._mb.get_release_group_tracks(release.mbid)
            editions = [r for r in data.get("releases") or [] if any(m.get("tracks") for m in r.get("media") or [])]
            if not editions:
                return empty
            full = await self._mb.get_release_credits(_canonical_edition(editions)["id"])
        except MusicBrainzError:
            return empty
        out = album_credits(full)
        # Lidé, které máme v katalogu (MBID) -- klepnutím na jejich stránku.
        mbids = [p["mbid"] for g in ("musicians", "writers", "production") for p in out[g] if p.get("mbid")]
        known = {
            a.mbid: a.id for a in self._session.exec(select(Artist).where(Artist.mbid.in_(mbids))).all()  # type: ignore[attr-defined]
        } if mbids else {}
        for g in ("musicians", "writers", "production"):
            for p in out[g]:
                p["artistId"] = known.get(p.get("mbid"))
        return out

    async def get_release_tracks(self, release_id: str) -> list[RecordingOut] | None:
        # GET nesmí spadnout na 500 jen proto, že zápis drží worker/nástroj
        # (load test: "database is locked") -- zápisy jsou jen doplňky
        # katalogu, příště se zkusí znovu. Pak tracklist z toho, co už je v DB.
        try:
            tracks = await self._get_release_tracks(release_id)
        except (OperationalError, IntegrityError) as exc:
            # IntegrityError: souběžné načtení téhož alba už řádek vložilo.
            if isinstance(exc, OperationalError) and not _is_locked(exc):
                raise
            self._session.rollback()
            logger.warning("album %s: zápis selhal (%s), tracklist jen z DB", release_id, type(exc).__name__)
            release = self._session.get(Release, release_id)
            return self._stored_release_tracks(release) if release is not None else None
        if tracks:
            # Kolik skladeb album má (různé názvy) -- Knihovna podle toho pozná
            # celá alba ("Jen celá alba").
            titles = sorted({(t.title or "").strip().lower() for t in tracks})
            count = len(titles)
            release = self._session.get(Release, release_id)
            refs = (release.external_refs or {}) if release is not None else {}
            if release is not None and (refs.get("tracklistCount") != count or refs.get("tracklistTitles") != titles):
                release.external_refs = {**refs, "tracklistCount": count, "tracklistTitles": titles}
                self._session.add(release)
                try:
                    self._session.commit()
                except OperationalError as exc:
                    if not _is_locked(exc):
                        raise
                    self._session.rollback()
        return tracks

    def _stored_release_tracks(self, release: Release) -> list[RecordingOut]:
        """Tracklist bez zápisu: uložené pořadí (`tracklistIds`), jinak
        skladby alba bez těch z jiných edic."""
        from app.catalog.canonical import album_recordings

        return [self._to_recording_out(r) for r in album_recordings(self._session, release)]

    async def _get_release_tracks(self, release_id: str) -> list[RecordingOut] | None:
        release = self._session.get(Release, release_id)
        if release is None:
            return None
        # Album jen na YouTube / vlastní (Kontrast): tracklist zná jen naše DB
        # (živě: "No Phun Intended" z odkazu na YouTube ukazovalo 0 skladeb).
        if (release.external_refs or {}).get("source") in ("youtube", "soundcloud", "manual") or is_own_id(release.mbid):
            return self._local_release_tracks(release)
        if release.mbid is None:
            return await self._deezer_release_tracks(release) or self._local_release_tracks(release)

        try:
            data = await self._mb.get_release_group_tracks(release.mbid)
        except MusicBrainzError:
            return await self._deezer_release_tracks(release)

        # Jedna kanonická edice stačí pro osobní katalog -- první, která
        # skladby opravdu má (některé edice v MB mají prázdná média).
        mb_releases = [
            r for r in data.get("releases") or [] if any(m.get("tracks") for m in r.get("media") or [])
        ]
        if not mb_releases:
            return await self._deezer_release_tracks(release)
        chosen = _canonical_edition(mb_releases)
        # Stav vydání z MB: žádná oficiální edice = bootleg/promo (verze z něj
        # nejsou studiovky). Viditelné zůstává vše, jen stahování to ví.
        statuses = sorted({(r.get("status") or "").lower() for r in data.get("releases") or []} - {""})
        refs = release.external_refs or {}
        if statuses and refs.get("mbStatuses") != statuses:
            release.external_refs = {**refs, "mbStatuses": statuses}
            self._session.add(release)

        recordings: list[Recording] = []
        media = [m for m in chosen.get("media", []) if m.get("tracks")]
        chosen_mbids = {
            (t.get("recording") or {}).get("id") or t.get("id") for m in media for t in m.get("tracks") or []
        }
        # Starší řádky alba (soubor/poslechy z dřívější kanonické edice) --
        # viz `_reuse_referenced_row`.
        album_rows = list(self._session.exec(select(Recording).where(Recording.release_id == release.id)).all())
        claimed: set[str] = set()
        # Víc disků: čísla průběžně přes všechny disky (2CD Marsyas: 1..31),
        # jinak se disky prolínaly (1, 1, 2, 2...). Tak i vinylové strany "A1".
        position = 0
        for medium in media:
            for track in medium.get("tracks", []):
                position += 1
                rec_json = track.get("recording", {})
                title = rec_json.get("title") or track.get("title")
                if not title:
                    continue
                isrcs = rec_json.get("isrcs") or []
                # Interpret skladby, ne alba: u soundtracků/kompilací MB alba
                # připíše celé jednomu jménu (živě: Pelíšky -> všech 31 skladeb
                # "Boleslav Polívka", pak se stahovalo "Polívka – Lékořice").
                track_artist = self._ingest_artist_credit(track.get("artist-credit") or rec_json.get("artist-credit"))
                mbid = rec_json.get("id") or track.get("id")
                duration_ms = rec_json.get("length") or track.get("length")
                track_number = position if len(media) > 1 else _parse_track_number(track.get("number"))
                if mbid:
                    self._reuse_referenced_row(
                        release, album_rows, mbid, title, duration_ms, track_number, chosen_mbids, claimed
                    )
                recording = upsert_recording(
                    self._session,
                    mbid=mbid,
                    release_id=release.id,
                    artist_id=track_artist.id if track_artist else release.artist_id,
                    title=title,
                    duration_ms=duration_ms,
                    isrc=isrcs[0] if isrcs else None,
                    track_number=track_number,
                    disambiguation=rec_json.get("disambiguation") if rec_json else None,
                )
                claimed.add(recording.id)
                if (recording.external_refs or {}).get("otherEdition"):
                    # Dřív z jiné edice, teď v tracklistu tohohle alba.
                    recording.external_refs = {k: v for k, v in recording.external_refs.items() if k != "otherEdition"}
                recordings.append(recording)

        await self._enrich_recording_previews(recordings)
        recordings.sort(key=lambda r: (r.track_number is None, r.track_number or 0))
        self._fix_release_type(release, recordings)
        refs = release.external_refs or {}
        ids = [r.id for r in recordings]
        if refs.get("tracklistIds") != ids:
            release.external_refs = {**refs, "tracklistIds": ids}
            self._session.add(release)
        # Hned potvrdit: nepotvrzený zápis (flush) jinak držel zámek SQLite
        # až do konce požadavku a ostatní zápisy (i v jiných požadavcích)
        # na něj čekaly -- při zátěži stálo celé API 5 s (zátěžový test).
        self._session.commit()
        self._ingest_other_editions(release, mb_releases, chosen)
        return [self._to_recording_out(r) for r in recordings]

    def _reuse_referenced_row(
        self,
        release: Release,
        album_rows: list[Recording],
        mbid: str,
        title: str,
        duration_ms: int | None,
        track_number: int | None,
        chosen_mbids: set[str | None],
        claimed: set[str],
    ) -> None:
        """Po změně kanonické edice: nová MB nahrávka by založila nový řádek
        a starý (se souborem, poslechy, lajky) by z alba vypadl. Starý řádek
        téže skladby (název, ±3 s) proto převezme nové MBID; řádek, který ho
        už má bez souboru, se do něj sloučí."""
        from app.catalog.canonical import adopt_mbid, find_referenced_twin

        holder = self._session.exec(select(Recording).where(Recording.mbid == mbid)).first()
        if holder is not None:
            if holder.release_id != release.id:
                return  # nahrávka jiného alba (singl) -- přes alba neslučovat
            asset = self._session.get(MediaAsset, holder.id)
            if asset is not None and asset.status == MediaAssetStatus.AVAILABLE:
                return  # už má soubor, není co zachraňovat
        # Řádky jiných skladeb tohohle tracklistu nebo už použité se neberou.
        exclude = set(claimed) | {r.id for r in album_rows if r.mbid in chosen_mbids}
        twin = find_referenced_twin(self._session, album_rows, title, duration_ms, track_number, exclude)
        if twin is None:
            return
        logger.info("album %s: '%s' -- starý řádek %s převzal MBID %s", release.id, title, twin.id, mbid)
        adopt_mbid(self._session, twin, mbid)
        if holder is not None and holder.id != twin.id:
            album_rows[:] = [r for r in album_rows if r.id != holder.id]
        self._session.commit()

    def _ingest_other_editions(self, release: Release, editions: list[dict], chosen: dict) -> None:
        """Skladby z ostatních edic téhož alba (jiné pásky koncertu, bonusy
        reedic, Atmos mixy) -- ať se dají najít ("vždy co nejvíc hudby").
        Ze stejné odpovědi MB, žádné dotazy navíc. Jen nahrávky, které v DB
        ještě nejsou (cizí album jim nebereme), označené `otherEdition`;
        tracklist alba je neukazuje, mají vlastní sekci a ve vyhledávání jdou
        až za oficiálními."""
        seen: set[str] = set()
        candidates: list[tuple[dict, dict, dict]] = []
        for edition in editions:
            if edition is chosen:
                continue
            for medium in edition.get("media") or []:
                for track in medium.get("tracks") or []:
                    rec_json = track.get("recording") or {}
                    mbid = rec_json.get("id")
                    if mbid and mbid not in seen and (rec_json.get("title") or track.get("title")):
                        seen.add(mbid)
                        candidates.append((edition, medium, track))
        if not candidates:
            return
        known = set(self._session.exec(select(Recording.mbid).where(Recording.mbid.in_(list(seen)))).all())  # type: ignore[union-attr]
        added = 0
        for edition, medium, track in candidates:
            rec_json = track.get("recording") or {}
            if rec_json["id"] in known:
                continue
            isrcs = rec_json.get("isrcs") or []
            track_artist = self._ingest_artist_credit(track.get("artist-credit") or rec_json.get("artist-credit"))
            label = " · ".join(
                x for x in (
                    (edition.get("disambiguation") or "").strip(),
                    (medium.get("title") or "").strip(),
                    (edition.get("date") or "")[:4],
                    edition.get("country") or "",
                ) if x
            )
            refs = {"otherEdition": label or "jiná edice"}
            if (rec_json.get("disambiguation") or "").strip():
                refs["mbDisambiguation"] = rec_json["disambiguation"].strip()
            row = Recording(
                mbid=rec_json["id"],
                release_id=release.id,
                artist_id=track_artist.id if track_artist else release.artist_id,
                title=rec_json.get("title") or track.get("title"),
                duration_ms=rec_json.get("length") or track.get("length"),
                isrc=isrcs[0] if isrcs else None,
                track_number=None,
                external_refs=refs,
            )
            # Souběžné otevření téhož alba vkládá stejná MBID -- unikátní
            # klíč by shodil celý tracklist (500); duplicitu jen přeskočit.
            done = self._session.execute(
                sqlite_insert(Recording).values(**row.model_dump()).on_conflict_do_nothing()
            )
            added += done.rowcount or 0
        if added:
            self._session.commit()
            logger.info("album %s: %d skladeb z jiných edic", release.id, added)

    def _fix_release_type(self, release: Release, recordings: list[Recording]) -> None:
        """"Album" o 1-2 skladbách patří mezi singly/EP (živě nahlášeno:
        na stránce interpreta mezi alby). Pravidlo jako u streamovacích
        služeb: do 3 skladeb a 30 min singl, 4-6 skladeb do 30 min EP.
        Opraví se při načtení tracklistu a uloží (diskografie se pak řadí
        správně)."""
        if release.release_type != "album" or not recordings or (release.external_refs or {}).get("typeByTracks"):
            return
        n = len({(r.track_number, r.title) for r in recordings})
        total_ms = sum(r.duration_ms or 0 for r in recordings)
        short = total_ms and total_ms < 30 * 60 * 1000
        new_type = "single" if n <= 2 or (n <= 3 and short) else ("ep" if n <= 6 and short else None)
        if new_type:
            # Zvlášť od `release_type`: ten MB/Deezer při obnově diskografie přepíše.
            release.external_refs = {**(release.external_refs or {}), "typeByTracks": new_type}
            self._session.add(release)
            self._session.commit()

    def _local_release_tracks(self, release: Release) -> list[RecordingOut]:
        recordings = list(self._session.exec(select(Recording).where(Recording.release_id == release.id)).all())
        recordings.sort(key=lambda r: (r.track_number is None, r.track_number or 0, r.title))
        return [self._to_recording_out(r) for r in recordings]

    async def _deezer_release_tracks(self, release: Release) -> list[RecordingOut]:
        """Tracklist alba z Deezeru -- pro alba bez MBID (z Deezer hledání/
        žebříčků) nebo když MusicBrainz selže/nic nemá."""
        if not release.deezer_id:
            # MusicBrainz tracklist nemá (čerstvé album, prázdná edice) a
            # Deezer id jsme ještě neznali -- dohledat album jménem.
            artist = self._session.get(Artist, release.artist_id)
            candidates = await self._dz.search_album(artist.name, release.title) if artist else []
            if artist and clean_album_title(release.title) != release.title:
                # "Black Currents EP" vs. Deezer "Black Currents".
                candidates = [*(candidates or []), *await self._dz.search_album(artist.name, clean_album_title(release.title))]
            wanted = {norm(release.title), norm(clean_album_title(release.title))}
            match = next(
                (
                    a
                    for a in candidates or []
                    if {norm(a.get("title")), norm(clean_album_title(a.get("title") or ""))} & wanted
                    and norm((a.get("artist") or {}).get("name")) == norm(artist.name)
                ),
                None,
            )
            if match is None:
                return []
            release.deezer_id = str(match["id"])
            if not release.images and deezer_image(match.get("cover_xl") or match.get("cover_big")):
                release.images = [deezer_image(match.get("cover_xl") or match.get("cover_big"))]
            self._session.add(release)
            self._session.commit()
        tracks = await self._dz.album_tracks(release.deezer_id)
        if not tracks:
            return []
        album_artist = self._session.get(Artist, release.artist_id)
        recordings: list[Recording] = []
        for position, item in enumerate(tracks, start=1):
            track_artist = ingest_artist(self._session, item.get("artist") or {}) or album_artist
            recording = ingest_track(self._session, {"track_position": position, **item}, artist=track_artist, release=release)
            if recording is not None:
                recordings.append(recording)
        self._session.commit()
        recordings.sort(key=lambda r: (r.track_number is None, r.track_number or 0))
        self._fix_release_type(release, recordings)
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
                for medium in _canonical_edition(mb_releases).get("media", [])
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

    async def _enrich_release_date(self, release: Release) -> None:
        """Rok vydání u alb z Deezeru: výsledky hledání a skladby nesou jen
        zkrácené album bez `release_date`, takže většina alb rok neměla
        (živě: detail alba bez roku). Doplní se při otevření detailu."""
        if release.release_date or not release.deezer_id:
            return
        album = await self._dz.album(release.deezer_id)
        date = (album or {}).get("release_date")
        # Deezer u neznámého data vrací "0000-00-00".
        if date and not date.startswith("0000"):
            release.release_date = date
            self._session.add(release)
            self._session.commit()

    async def _enrich_release_genres(self, release: Release) -> None:
        if release.genres or not release.mbid:
            return
        try:
            data = await self._mb.get_release_group(release.mbid)
        except MusicBrainzError:
            return
        # Nejsilnější první (MB je vrací abecedně, s počtem hlasů).
        ranked = sorted((g for g in data.get("genres", []) if g.get("name")), key=lambda g: -(g.get("count") or 0))
        genres = [g["name"] for g in ranked]
        if genres:
            release.genres = genres
            self._session.add(release)
            self._session.commit()

    def _store_credits(self, release: Release, artist_credit: list[dict[str, Any]]) -> None:
        """Všichni interpreti alba (spolupráce "Chris Thile & Michael Daves")
        do `external_refs.credits` -- `artist_id` nese jen prvního. Jen když
        jich je víc; jinak klíč pryč. `creditsChecked`, ať se MB neptá znovu."""
        credits: list[dict[str, Any]] = []
        if len(artist_credit) > 1:
            for c in artist_credit:
                a = c.get("artist") or {}
                if not a.get("name"):
                    continue
                row = upsert_artist(self._session, mbid=a.get("id"), name=a["name"], sort_name=a.get("sort-name"))
                credits.append({"id": row.id, "name": c.get("name") or a["name"], "join": c.get("joinphrase") or ""})
        refs = {k: v for k, v in (release.external_refs or {}).items() if k != "credits"}
        if len(credits) > 1:
            refs["credits"] = credits
        refs["creditsChecked"] = True
        if refs != (release.external_refs or {}):
            release.external_refs = refs
            self._session.add(release)
            self._session.commit()

    def store_deezer_credits(self, release: Release, contributors: list[dict[str, Any]]) -> None:
        """Hlavní účinkující alba z Deezeru (viz deezer_ingest.main_credits)."""
        from app.catalog.deezer_ingest import apply_credits, main_credits

        if apply_credits(release, main_credits(self._session, contributors), release.artist_id):
            self._session.add(release)
            self._session.commit()

    async def _enrich_release_credits(self, release: Release) -> None:
        refs = release.external_refs or {}
        if refs.get("creditsChecked") or is_own_id(release.mbid) or is_own_id(release.deezer_id):
            return
        if not release.mbid:
            # Album jen z Deezeru: hlavní účinkující alba ("Norman Blake &
            # Tony Rice 2" -- Deezer má oba jako Main, dřív jen první).
            if release.deezer_id and release.deezer_id.isdigit():
                album = await self._dz.album(release.deezer_id)
                if album is not None:
                    self.store_deezer_credits(release, album.get("contributors") or [])
            return
        try:
            data = await self._mb.get_release_group(release.mbid)
        except MusicBrainzError:
            return
        if data.get("artist-credit"):
            self._store_credits(release, data["artist-credit"])

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


def _is_locked(exc: OperationalError) -> bool:
    text = str(exc).lower()
    return "locked" in text or "busy" in text


def _real_id(value: str | None) -> str | None:
    return None if value is None or value.startswith("own:") else value
