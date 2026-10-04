"""Generátory sekcí Domů. Každý je izolovaný: selhání jednoho (zdroj
nedostupný, změněné API) nikdy nesmaže poslední dobrý snapshot ani
nezastaví ostatní -- viz `home_refresh_loop`.

Zdroje (vše zdarma, bez klíče, ověřeno živě):
  - Deezer žebříčkové playlisty Top Worldwide / Top USA / Top Czech Republic
    (pevná id -- `/chart/0` je podle IP a "globální" by tak nebyl globální)
  - Deezer žánrové žebříčky `/chart/{genre}/tracks`
  - Deezer redakční výběry `/chart/0/playlists` (nálady, dekády, styly)
  - Apple Music RSS "most played" US + CZ (bez ISRC -> párování přes Deezer)
  - ListenBrainz fresh releases (nová alba z posledních 14 dní)
  - osobní mixy z `RecommendationService` (Discover, Moje top, Trendy, Komunita)
"""

from __future__ import annotations

import asyncio
import logging
import os
from contextvars import ContextVar, Token
from dataclasses import dataclass
from datetime import date, timedelta
from typing import Any, Awaitable, Callable

import httpx
from sqlmodel import Session, select

from app.library.dislikes import without_disliked
from app.apple_http import apple_http
from app.catalog.deezer import get_deezer_client
from app.catalog.deezer_ingest import ingest_track_with_context
from app.catalog.upsert import upsert_artist, upsert_release
from app.db import engine
from app.models import (
    GLOBAL_PLAYLIST_OWNER,
    Artist,
    HomeSnapshot,
    MediaAsset,
    MediaAssetStatus,
    Playlist,
    PlaylistItem,
    PlaylistKind,
    Recording,
    Release,
)
from app.provisioning_service import enqueue, get_or_create_job
from app.recommendations.anti_ai_filter import AntiAIFilter
from app.redis_bus import get_redis
from app.utils import utcnow

logger = logging.getLogger(__name__)

HOME_USER_ID = os.environ.get("HOME_USER_ID", "demo-user")

# Profil, pro který se právě generují osobní mixy (každý profil má své --
# generátory běží postupně pro všechny, viz `service.run_generators`).
# Výchozí = admin (dosavadní chování).
_home_user: ContextVar[str] = ContextVar("home_user", default=HOME_USER_ID)


def home_user() -> str:
    return _home_user.get()


def set_home_user(user_id: str) -> Token:
    return _home_user.set(user_id)


def reset_home_user(token: Token) -> None:
    _home_user.reset(token)


def _scoped(key: str) -> str:
    """Osobní snapshoty ("už postaveno dnes", výběr kategorií...) zvlášť
    pro každý profil; adminovy klíče beze změny (stará data platí dál)."""
    user = home_user()
    if user == HOME_USER_ID or not key.startswith(("personal:", "gen:personal:")):
        return key
    return f"{key}@{user}"
LISTENBRAINZ_USERNAME = os.environ.get("LISTENBRAINZ_USERNAME", "demo-user")

CHART_TTL = timedelta(hours=6)
DAILY_TTL = timedelta(hours=24)

# Pauza mezi Deezer dotazy generátorů -- sdílí rate limiter s hledáním,
# fronta se tak nikdy nenahromadí a uživatelovo hledání čeká nejvýš 1 slot.
_BACKGROUND_GAP_S = 0.35
_PREPROVISION_PER_PLAYLIST = 2
_PREPROVISION_DAILY_CAP = 30

_anti_ai = AntiAIFilter()
_http = httpx.AsyncClient(timeout=20.0)


@dataclass(frozen=True)
class DeezerPlaylistSpec:
    source: str
    title: str
    description: str
    kind: PlaylistKind
    section: str
    fetch: Callable[[], Awaitable[list[dict[str, Any]] | None]]
    preprovision: bool = False


def _chart_specs() -> list[DeezerPlaylistSpec]:
    dz = get_deezer_client()

    def playlist(pid: str) -> Callable[[], Awaitable[list[dict[str, Any]] | None]]:
        return lambda: dz.playlist_tracks(pid, 100)

    return [
        DeezerPlaylistSpec(
            "deezer:playlist:3155776842", "Top Worldwide", "100 nejhranějších skladeb světa", PlaylistKind.CHART, "charts",
            playlist("3155776842"), preprovision=True,
        ),
        DeezerPlaylistSpec(
            "deezer:playlist:1313621735", "Top USA", "100 nejhranějších v USA -- nejblíž Billboard Hot 100", PlaylistKind.CHART,
            "charts", playlist("1313621735"), preprovision=True,
        ),
        DeezerPlaylistSpec(
            "deezer:playlist:1266969571", "Top Česko", "Co se teď nejvíc hraje v Česku", PlaylistKind.CHART, "charts",
            playlist("1266969571"), preprovision=True,
        ),
    ]


GENRES: list[tuple[int, str]] = [
    (132, "Pop"),
    (116, "Rap / Hip Hop"),
    (152, "Rock"),
    (85, "Alternativa"),
    (113, "Dance"),
    (106, "Electro"),
    (165, "R&B"),
    (464, "Metal"),
]


def _genre_specs() -> list[DeezerPlaylistSpec]:
    dz = get_deezer_client()
    return [
        DeezerPlaylistSpec(
            f"deezer:chart:genre:{gid}", name, f"Žebříček žánru {name} podle Deezeru", PlaylistKind.GENRE, "genres",
            (lambda gid=gid: dz.chart_tracks(gid, 50)),
        )
        for gid, name in GENRES
    ]


# --------------------------------------------------------------------------
# Snapshot helpers
# --------------------------------------------------------------------------


def _save_playlist(
    *,
    owner: str,
    source: str,
    title: str,
    description: str | None,
    kind: PlaylistKind,
    section: str,
    recording_ids: list[str],
    cover_urls: list[str],
    ttl: timedelta,
) -> str:
    with Session(engine) as session:
        playlist = session.exec(select(Playlist).where(Playlist.owner_user_id == owner, Playlist.source == source)).first()
        if playlist is None:
            playlist = Playlist(owner_user_id=owner, title=title, kind=kind, source=source)
            session.add(playlist)
            session.flush()
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all():
            session.delete(item)
        # Zlomená srdce do žádného výběru.
        for position, recording_id in enumerate(without_disliked(owner, recording_ids)):
            session.add(PlaylistItem(playlist_id=playlist.id, recording_id=recording_id, position=position))
        now = utcnow()
        playlist.title = title
        playlist.description = description
        playlist.kind = kind
        playlist.section = section
        playlist.cover_urls = cover_urls[:4]
        playlist.generated_at = now
        playlist.expires_at = now + ttl
        playlist.updated_at = now
        session.add(playlist)
        session.commit()
        return playlist.id


def _covers_for(recording_ids: list[str]) -> list[str]:
    """První 4 RŮZNÉ obaly alb -- mozaika 2x2 na kartě playlistu."""
    covers: list[str] = []
    with Session(engine) as session:
        for recording_id in recording_ids:
            recording = session.get(Recording, recording_id)
            release = session.get(Release, recording.release_id) if recording and recording.release_id else None
            cover = release.images[0] if release and release.images else None
            if cover is None and recording is not None and recording.artist_id:
                # Mixy z ListenBrainz nemají album -- aspoň fotka interpreta.
                artist = session.get(Artist, recording.artist_id)
                cover = artist.images[0] if artist and artist.images else None
            if cover and cover not in covers:
                covers.append(cover)
            if len(covers) == 4:
                break
    return covers


def _ingest_tracks(tracks: list[dict[str, Any]]) -> list[str]:
    """Synchronní -- bez `await` uvnitř (viz app/catalog/deezer_ingest.py)."""
    ids: list[str] = []
    with Session(engine) as session:
        for item in tracks:
            if _anti_ai.is_blocked_text((item.get("artist") or {}).get("name"), item.get("title")):
                continue
            recording = ingest_track_with_context(session, item)
            if recording is not None and recording.id not in ids:
                ids.append(recording.id)
        session.commit()
    return ids


async def _preprovision(recording_ids: list[str]) -> None:
    """První skladby žebříčků předem stáhnout (NE-interaktivní fronta), ať
    se na Domů pouští okamžitě. Denní strop -- žebříčky se mění, ať to
    nezahltí Soulseek/YouTube."""
    redis = get_redis()
    key = f"home:preprovision:{date.today().isoformat()}"
    for recording_id in recording_ids[:_PREPROVISION_PER_PLAYLIST]:
        with Session(engine) as session:
            asset = session.get(MediaAsset, recording_id)
            if asset is not None and asset.status == MediaAssetStatus.AVAILABLE:
                continue
            used = int(await redis.get(key) or 0)
            if used >= _PREPROVISION_DAILY_CAP:
                return
            _asset, job, created = get_or_create_job(session, recording_id, HOME_USER_ID, None)
            if job is not None and created:
                await enqueue(job, interactive=False)
                await redis.incr(key)
                await redis.expire(key, 2 * 24 * 60 * 60)


async def build_deezer_playlist(spec: DeezerPlaylistSpec, ttl: timedelta) -> int:
    tracks = await spec.fetch()
    if not tracks:
        raise RuntimeError(f"{spec.source}: zdroj nevrátil žádné skladby")
    recording_ids = _ingest_tracks(tracks)
    if not recording_ids:
        raise RuntimeError(f"{spec.source}: žádnou skladbu nešlo napojit")
    _save_playlist(
        owner=GLOBAL_PLAYLIST_OWNER,
        source=spec.source,
        title=spec.title,
        description=spec.description,
        kind=spec.kind,
        section=spec.section,
        recording_ids=recording_ids,
        cover_urls=_covers_for(recording_ids),
        ttl=ttl,
    )
    if spec.preprovision:
        await _preprovision(recording_ids)
    return len(recording_ids)


async def build_editorial() -> int:
    """Deezer redakční playlisty (nálady/dekády/styly) -- hotové, s ISRC."""
    dz = get_deezer_client()
    playlists = await dz.chart_playlists(12)
    if not playlists:
        raise RuntimeError("deezer editorial: žádné playlisty")
    built = 0
    for meta in playlists:
        pid = str(meta.get("id"))
        tracks = await dz.playlist_tracks(pid, 60)
        await asyncio.sleep(_BACKGROUND_GAP_S)
        if not tracks:
            continue
        recording_ids = _ingest_tracks(tracks)
        if not recording_ids:
            continue
        _save_playlist(
            owner=GLOBAL_PLAYLIST_OWNER,
            source=f"deezer:playlist:{pid}",
            title=meta.get("title") or "Výběr",
            description="Výběr redakce Deezeru",
            kind=PlaylistKind.EDITORIAL,
            section="editorial",
            recording_ids=recording_ids,
            cover_urls=_covers_for(recording_ids),
            ttl=DAILY_TTL,
        )
        built += 1
    return built


async def build_apple_chart(country: str, title: str, description: str) -> int:
    """Apple Music RSS nemá ISRC -- každou položku napáruje Deezer hledání
    "interpret + název" (pomalu, s pauzou, ať nezdržuje uživatelské hledání)."""
    url = f"https://rss.marketingtools.apple.com/api/v2/{country}/music/most-played/50/songs.json"
    client = apple_http()
    if client is None:
        raise RuntimeError("apple rss: chybí VPN proxy, Apple se z domácí IP nevolá")
    resp = await client.get(url)
    resp.raise_for_status()
    entries = (resp.json().get("feed") or {}).get("results") or []
    if not entries:
        raise RuntimeError(f"apple rss {country}: prázdný feed")
    dz = get_deezer_client()
    tracks: list[dict[str, Any]] = []
    for entry in entries:
        match = await dz.find_track(entry.get("artistName", ""), entry.get("name", ""))
        if match:
            tracks.append(match)
        await asyncio.sleep(_BACKGROUND_GAP_S)
    recording_ids = _ingest_tracks(tracks)
    if len(recording_ids) < len(entries) // 3:
        raise RuntimeError(f"apple rss {country}: napárováno jen {len(recording_ids)}/{len(entries)}")
    _save_playlist(
        owner=GLOBAL_PLAYLIST_OWNER,
        source=f"apple:rss:{country}",
        title=title,
        description=description,
        kind=PlaylistKind.CHART,
        section="charts",
        recording_ids=recording_ids,
        cover_urls=_covers_for(recording_ids),
        ttl=CHART_TTL,
    )
    return len(recording_ids)


async def build_new_releases() -> int:
    """ListenBrainz fresh releases -> alba s obalem (Cover Art Archive),
    seřazená podle počtu poslechů. Tracklisty se dotáhnou až při otevření
    (běžná MusicBrainz cesta, MBID tu máme)."""
    resp = await _http.get(
        "https://api.listenbrainz.org/1/explore/fresh-releases/",
        params={"days": 30, "sort": "release_date", "future": "false"},
    )
    resp.raise_for_status()
    releases = (resp.json().get("payload") or {}).get("releases") or []
    candidates = [
        r
        for r in releases
        if r.get("caa_id")
        and r.get("release_group_mbid")
        and r.get("artist_mbids")
        and (r.get("release_group_primary_type") or "").lower() in ("album", "ep")
        and not _anti_ai.is_blocked_text(r.get("artist_credit_name"), r.get("release_name"))
    ]
    # LB nová vydání nemají počty poslechů (živě: 0 z 4058) -- relevanci dá
    # to, že interpreta už známe (knihovna, žebříčky, hledání), pak novost.
    with Session(engine) as session:
        # "Relevantní" = interpret z knihovny nebo z některého playlistu
        # (žebříčky, žánry, mixy, vlastní) -- ne každý, kdo se kdy objevil
        # ve výsledcích hledání (živě: Merzbow a noise projekty navrchu).
        relevant_artist_ids = set(
            session.exec(
                select(Recording.artist_id).join(MediaAsset, MediaAsset.recording_id == Recording.id)
                .where(MediaAsset.status == MediaAssetStatus.AVAILABLE)
            ).all()
        ) | set(
            session.exec(select(Recording.artist_id).join(PlaylistItem, PlaylistItem.recording_id == Recording.id)).all()
        )
        known = {
            a.mbid
            for a in session.exec(select(Artist).where(Artist.mbid.is_not(None))).all()  # type: ignore[union-attr]
            if a.id in relevant_artist_ids
        }
    newest_first = sorted(candidates, key=lambda r: r.get("release_date") or "", reverse=True)
    seen_artists: set[str] = set()
    picked: list[dict[str, Any]] = []
    for item in newest_first:
        mbid = item["artist_mbids"][0]
        if mbid in known and mbid not in seen_artists:
            seen_artists.add(mbid)
            picked.append(item)
    candidates = picked
    release_ids: list[str] = []
    with Session(engine) as session:
        for item in candidates[:30]:
            artist = upsert_artist(
                session, mbid=item["artist_mbids"][0], name=item.get("artist_credit_name") or "Unknown", sort_name=None
            )
            release = upsert_release(
                session,
                mbid=item["release_group_mbid"],
                artist_id=artist.id,
                title=item.get("release_name") or "Untitled",
                release_date=item.get("release_date"),
                release_type=(item.get("release_group_primary_type") or "album").lower(),
            )
            if not release.images and item.get("caa_release_mbid"):
                release.images = [f"https://coverartarchive.org/release/{item['caa_release_mbid']}/front-500"]
                session.add(release)
                session.commit()
            if release.id not in release_ids:
                release_ids.append(release.id)
    if len(release_ids) < 4:
        raise RuntimeError(f"fresh releases: jen {len(release_ids)} od známých interpretů")
    _save_snapshot("new_releases", {"releaseIds": release_ids})
    return len(release_ids)


async def build_top_albums() -> int:
    """Apple Music nejhranější alba (US + CZ) -> Deezer album (obal, tracklist)."""
    from app.catalog.deezer_ingest import ingest_album, ingest_artist, norm

    dz = get_deezer_client()
    matched: list[dict[str, Any]] = []
    client = apple_http()
    if client is None:
        raise RuntimeError("apple rss: chybí VPN proxy, Apple se z domácí IP nevolá")
    for country in ("us", "cz"):
        resp = await client.get(f"https://rss.marketingtools.apple.com/api/v2/{country}/music/most-played/25/albums.json")
        resp.raise_for_status()
        for entry in (resp.json().get("feed") or {}).get("results") or []:
            artist_name, title = entry.get("artistName", ""), entry.get("name", "")
            if _anti_ai.is_blocked_text(artist_name, title):
                continue
            albums = await dz.search_album(artist_name, title) or []
            await asyncio.sleep(_BACKGROUND_GAP_S)
            hit = next((a for a in albums if norm(a.get("title")) == norm(title)), albums[0] if albums else None)
            if hit is not None:
                matched.append(hit)
    release_ids: list[str] = []
    with Session(engine) as session:
        for album in matched:
            artist = ingest_artist(session, album.get("artist") or {})
            release = ingest_album(session, album, artist) if artist else None
            if release is not None and release.id not in release_ids:
                release_ids.append(release.id)
        session.commit()
    if len(release_ids) < 10:
        raise RuntimeError(f"top albums: napárováno jen {len(release_ids)}")
    _save_snapshot("top_albums", {"releaseIds": release_ids})
    return len(release_ids)


def _listenbrainz_user(user_id: str) -> str | None:
    from app.models import AppUser

    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        if user is not None and user.listenbrainz_user:
            return user.listenbrainz_user
    if user_id == HOME_USER_ID:
        return os.environ.get("LISTENBRAINZ_USERNAME") or None
    return None


async def build_personal_mixes() -> int:
    """Discover / Moje top / Trendy / Komunita jako playlisty (karty na
    Domů), plus Daily Jams, který už playlist je."""
    from app.recommendations.listenbrainz import get_listenbrainz_client, get_listenbrainz_public_client
    from app.recommendations.service import RecommendationService

    # Každý profil ze SVÉHO ListenBrainz účtu (Profil › ListenBrainz); bez
    # připojeného účtu tyhle mixy nemá -- nikdy ne z cizího (adminova).
    owner = home_user()
    lb_user = _listenbrainz_user(owner)
    if not lb_user:
        return 0
    built = 0
    with Session(engine) as session:
        service = RecommendationService(session, get_listenbrainz_client(), get_listenbrainz_public_client())
        try:
            await service.daily_jams(owner, lb_user)
            built += 1
        except Exception:  # noqa: BLE001
            logger.exception("home: daily jams selhal")
        mixes: list[tuple[str, str, str, Callable[[], Awaitable[list[Any]]]]] = [
            ("home:mix:discover", "Objevuj", "Nová hudba podle tvého poslechu", lambda: service.discover(lb_user, 40)),
            ("home:mix:my-top", "Moje nejposlouchanější", "Tvoje top skladby za měsíc", lambda: service.my_top_tracks(lb_user, 40)),
            ("home:mix:trending", "Trendy na ListenBrainz", "Co se tento týden nejvíc poslouchá", lambda: service.trending(40)),
            ("home:mix:community", "Komunitní objevy", "Tipy od komunity ListenBrainz", lambda: service.community_picks(lb_user, 40)),
        ]
        for source, title, description, fetch in mixes:
            try:
                recordings = await fetch()
            except Exception:  # noqa: BLE001
                logger.exception("home: mix %s selhal", source)
                continue
            ids = [r.id for r in recordings]
            if not ids:
                continue
            _save_playlist(
                owner=owner,
                source=source,
                title=title,
                description=description,
                kind=PlaylistKind.GENERATED_RECOMMENDATION,
                # Trendy jsou žebříček celého ListenBrainz, ne "Vytvořeno pro
                # tebe" -- se Žebříčky se i skrývají (tátovi 17x BTS mezi mixy).
                section="charts" if source == "home:mix:trending" else "mixes",
                recording_ids=ids,
                cover_urls=_covers_for(ids),
                ttl=DAILY_TTL,
            )
            built += 1
    return built


def _save_snapshot(key: str, payload: dict[str, Any]) -> None:
    key = _scoped(key)
    with Session(engine) as session:
        snapshot = session.get(HomeSnapshot, key) or HomeSnapshot(key=key)
        snapshot.payload = payload
        snapshot.generated_at = utcnow()
        session.add(snapshot)
        session.commit()


def load_snapshot(session: Session, key: str) -> HomeSnapshot | None:
    return session.get(HomeSnapshot, _scoped(key))
