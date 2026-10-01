"""`GET /home` + refresh smyčka generátorů (viz generators.py)."""

from __future__ import annotations

import asyncio
import logging
from datetime import datetime, timedelta, timezone
from typing import Any, Awaitable, Callable

from sqlmodel import Session, select

from app.catalog.availability import compute_availability, resolve_artist_name
from app.catalog.cache import CACHE_PREFIX, cached_json
from app.catalog.schemas import CamelModel, RecordingOut
from app.db import engine
from app.home import generators as g
from app.home import personal_mixes as pm
from app.models import GLOBAL_PLAYLIST_OWNER, Artist, HomeSnapshot, Playlist, PlaylistItem, Recording, Release
from app.redis_bus import get_redis
from app.utils import utcnow

logger = logging.getLogger(__name__)

HOME_CACHE_TTL_S = 5 * 60


class PlaylistCardOut(CamelModel):
    id: str
    title: str
    description: str | None = None
    kind: str
    source: str | None = None
    section: str | None = None
    cover_urls: list[str] = []
    item_count: int
    generated_at: datetime | None = None
    badge: str | None = None
    # Barva kategorie Procházet u "Tvůj mix · X" -- obal v barvě kategorie.
    accent_color: str | None = None
    # Generativní obal vlastních mixů: daily | genre | mood | year.
    art_style: str | None = None


class AlbumCardOut(CamelModel):
    id: str
    title: str
    artist_id: str
    artist_name: str | None = None
    release_date: str | None = None
    release_type: str
    images: list[str] = []


# --------------------------------------------------------------------------
# Refresh
# --------------------------------------------------------------------------


def _generator_registry() -> list[tuple[str, timedelta, Callable[[], Awaitable[int]]]]:
    registry: list[tuple[str, timedelta, Callable[[], Awaitable[int]]]] = []
    for spec in g._chart_specs():
        registry.append((spec.source, g.CHART_TTL, lambda spec=spec: g.build_deezer_playlist(spec, g.CHART_TTL)))
    registry.append(("apple:rss:us", g.CHART_TTL, lambda: g.build_apple_chart("us", "Apple Music Top 50: USA", "Nejhranější na Apple Music v USA")))
    registry.append(("apple:rss:cz", g.CHART_TTL, lambda: g.build_apple_chart("cz", "Apple Music Top 50: Česko", "Nejhranější na Apple Music v Česku")))
    registry.append(("personal:mixes", g.DAILY_TTL, g.build_personal_mixes))
    # Vlastní mixy: interně hlídají den (4:00) / týden, kontrola každou hodinu.
    registry.append(("personal:daily-mixes", timedelta(hours=1), pm.build_daily_mixes))
    registry.append(("personal:discover-weekly", timedelta(hours=1), pm.build_discover_weekly))
    registry.append(("personal:on-repeat", timedelta(hours=1), pm.build_on_repeat))
    registry.append(("personal:throwback", g.DAILY_TTL, pm.build_throwback))
    # Společné mixy dvojic (app/blends.py) -- denně.
    from app.blends import TTL as BLEND_TTL, build_for_current_user

    registry.append(("personal:blends", BLEND_TTL, build_for_current_user))
    from app.home import category_mixes as cm

    registry.append(("personal:category-mixes", timedelta(hours=1), cm.build_home_category_mixes))
    registry.append(("personal:years", g.DAILY_TTL, _build_years))
    from app import wrapped

    registry.append(("personal:wrapped", g.DAILY_TTL, wrapped.warm_all))
    registry.append(("lb:fresh-releases", g.DAILY_TTL, g.build_new_releases))
    registry.append(("apple:rss:albums", g.DAILY_TTL, g.build_top_albums))
    registry.append(("deezer:editorial", g.DAILY_TTL, g.build_editorial))
    from app import browse

    registry.append(("home:genre-rails", timedelta(hours=1), browse.build_genre_rails))
    return registry


async def _build_years() -> int:
    """"Tvoje top skladby <rok>" -- 1. ledna přibude právě skončený rok."""
    from app.library.spotify_history import build_year_playlists

    return len(await asyncio.to_thread(build_year_playlists, g.home_user()))


def _profile_ids() -> list[str]:
    """Admin první, pak ostatní profily."""
    from app.models import AppUser

    with Session(engine) as session:
        others = [u.id for u in session.exec(select(AppUser)).all() if u.id != g.HOME_USER_ID]
    return [g.HOME_USER_ID, *others]


def _last_success(name: str) -> datetime | None:
    with Session(engine) as session:
        snapshot = g.load_snapshot(session, f"gen:{name}")
        if snapshot is None:
            return None
        stamp = snapshot.generated_at
        return stamp if stamp.tzinfo else stamp.replace(tzinfo=timezone.utc)


async def invalidate_home_cache() -> None:
    redis = get_redis()
    async for key in redis.scan_iter(match=f"{CACHE_PREFIX}home:*"):
        await redis.delete(key)


async def run_generators(*, force: bool = False) -> dict[str, Any]:
    """Spustí všechny generátory, které jsou na řadě (nebo všechny s
    `force`). Každý zvlášť -- výjimka jednoho jen zaloguje, poslední dobrý
    snapshot zůstává."""
    report: dict[str, Any] = {}
    now = datetime.now(timezone.utc)
    for name, ttl, build in _generator_registry():
        # Osobní generátory postupně pro každý profil (každý má své mixy).
        users = _profile_ids() if name.startswith("personal:") else [g.HOME_USER_ID]
        for user_id in users:
            token = g.set_home_user(user_id)
            try:
                last = _last_success(name)
                if not force and last is not None and now - last < ttl:
                    continue
                label = name if user_id == g.HOME_USER_ID else f"{name}@{user_id}"
                try:
                    count = await build()
                except Exception as exc:  # noqa: BLE001 - izolace generátorů
                    logger.warning("home: generátor %s selhal: %s", label, exc)
                    report[label] = f"error: {exc}"
                    continue
                g._save_snapshot(f"gen:{name}", {"count": count})
                report[label] = count
            finally:
                g.reset_home_user(token)
            await asyncio.sleep(g._BACKGROUND_GAP_S)
    if any(isinstance(v, int) for v in report.values()):
        await invalidate_home_cache()
    return report


async def home_refresh_loop(check_every_s: float = 15 * 60) -> None:
    await asyncio.sleep(20)  # nezdržovat start API
    while True:
        try:
            report = await run_generators()
            if report:
                logger.info("home: refresh %s", report)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001
            logger.exception("home: refresh smyčka selhala")
        await asyncio.sleep(check_every_s)


# --------------------------------------------------------------------------
# GET /home
# --------------------------------------------------------------------------

_SECTION_ORDER: list[tuple[str, str, str]] = [
    ("mixes", "Vytvořeno pro tebe", "playlist_cards"),
    ("blends", "Společné mixy", "playlist_cards"),
    ("category_mixes", "Tvoje žánry", "playlist_cards"),
    ("years", "Tvoje roky", "playlist_cards"),
    ("charts", "Žebříčky", "playlist_cards"),
    ("new_releases", "Nová vydání", "album_cards"),
    ("top_albums", "Populární alba", "album_cards"),
    ("genres", "Žánry", "playlist_cards"),
    ("editorial", "Nálady a výběry", "playlist_cards"),
]

_BADGES = {
    "deezer:playlist:3155776842": "TOP 100",
    "deezer:playlist:1313621735": "TOP 100",
    "deezer:playlist:1266969571": "TOP 100",
    "apple:rss:us": "TOP 50",
    "apple:rss:cz": "TOP 50",
}


_MIX_ORDER = ["personal:daily-mix:", "personal:discover-weekly", "personal:on-repeat", "personal:throwback", "home:mix:"]


def _mix_order(playlist: Playlist) -> tuple[int, str]:
    source = playlist.source or ""
    for rank, prefix in enumerate(_MIX_ORDER):
        if source.startswith(prefix):
            return rank, source
    return len(_MIX_ORDER), source


def _item_count(session: Session, playlist_id: str) -> int:
    return len(session.exec(select(PlaylistItem.id).where(PlaylistItem.playlist_id == playlist_id)).all())


def _fallback_covers(session: Session, playlist_id: str) -> list[str]:
    """Playlisty vzniklé mimo generátory Domů (Daily Jams) nemají uloženou
    mozaiku -- spočítat z prvních položek."""
    ids = session.exec(
        select(PlaylistItem.recording_id).where(PlaylistItem.playlist_id == playlist_id).order_by(PlaylistItem.position).limit(40)
    ).all()
    return g._covers_for(list(ids))


def _accent_for(source: str | None) -> str | None:
    """Barva dlaždice kategorie -- stejná na Domů i v Hledat."""
    from app.browse import get_category

    for prefix in ("personal:category-mix:", "browse:genre:"):
        if source and source.startswith(prefix):
            category = get_category(source[len(prefix):])
            return category.color if category else None
    return None


def _art_style(source: str | None) -> str | None:
    source = source or ""
    if source.startswith("personal:daily-mix:"):
        return "daily"
    if source.startswith("personal:year:"):
        return "year"
    if source.startswith("personal:decade:"):
        return "decade"
    if source.startswith("browse:genre:"):
        return "genre"
    if source.startswith("personal:category-mix:"):
        from app.browse import get_category

        category = get_category(source.rsplit(":", 1)[-1])
        return category.group if category else "genre"
    return None


def _card(session: Session, playlist: Playlist) -> PlaylistCardOut:
    return PlaylistCardOut(
        accent_color=_accent_for(playlist.source),
        art_style=_art_style(playlist.source),
        id=playlist.id,
        title=playlist.title,
        description=playlist.description,
        kind=playlist.kind.value if hasattr(playlist.kind, "value") else str(playlist.kind),
        source=playlist.source,
        section=playlist.section,
        cover_urls=playlist.cover_urls or _fallback_covers(session, playlist.id),
        item_count=_item_count(session, playlist.id),
        generated_at=playlist.generated_at,
        badge=_BADGES.get(playlist.source or ""),
    )


def _recording_out(session: Session, recording: Recording) -> RecordingOut:
    return RecordingOut(
        id=recording.id,
        mbid=recording.mbid,
        release_id=recording.release_id,
        artist_id=recording.artist_id,
        artist_name=resolve_artist_name(session, recording.artist_id),
        title=recording.title,
        duration_ms=recording.duration_ms,
        isrc=recording.isrc,
        track_number=recording.track_number,
        availability=compute_availability(session, recording.id),
        preview_url=(recording.external_refs or {}).get("previewUrl"),
    )


def _playlist_tracks(session: Session, playlist_id: str, limit: int) -> list[RecordingOut]:
    items = session.exec(
        select(PlaylistItem).where(PlaylistItem.playlist_id == playlist_id).order_by(PlaylistItem.position).limit(limit)
    ).all()
    out = []
    for item in items:
        recording = session.get(Recording, item.recording_id)
        if recording is not None:
            out.append(_recording_out(session, recording))
    return out


def build_home(user_id: str) -> dict[str, Any]:
    with Session(engine) as session:
        playlists = session.exec(
            select(Playlist).where(
                Playlist.section.is_not(None),  # type: ignore[union-attr]
                Playlist.owner_user_id.in_([GLOBAL_PLAYLIST_OWNER, user_id]),  # type: ignore[attr-defined]
            )
        ).all()
        by_section: dict[str, list[Playlist]] = {}
        for playlist in playlists:
            by_section.setdefault(playlist.section or "", []).append(playlist)
        # Osobní mixy napřed (Denní mix 1-6, Objevy týdne, Na opakování,
        # Návrat do minulosti), pak mixy z ListenBrainz, když mají data. Dřív
        # tu byl "Daily Jams" -- jen zamíchané oblíbené, nahrazeno Denními mixy.
        by_section.get("mixes", []).sort(key=_mix_order)
        chart_order = list(_BADGES)
        by_section.get("charts", []).sort(key=lambda p: chart_order.index(p.source) if p.source in chart_order else 99)
        from app.home import category_mixes as cm

        picks = [f"personal:category-mix:{p}" for p in cm.picks_order()]
        by_section["category_mixes"] = sorted(
            (p for p in by_section.get("category_mixes", []) if p.source in picks), key=lambda p: picks.index(p.source)
        )
        # Playlisty dekády napřed, pak roky od nejnovějšího.
        years_section = by_section.get("years", [])
        years_section.sort(key=lambda p: p.source or "", reverse=True)
        years_section.sort(key=lambda p: not (p.source or "").startswith("personal:decade:"))  # stabilní
        # Žánry = přesně ty z Hledat (app/browse.py), ve stejném pořadí; staré
        # Deezer žebříčky se sekcí "genres" se už neukazují.
        from app import browse as _browse

        genre_order = [f"browse:genre:{c.id}" for c in _browse.CATEGORIES if c.group == "genre"]
        by_section["genres"] = sorted(
            (p for p in by_section.get("genres", []) if p.source in genre_order),
            key=lambda p: genre_order.index(p.source),
        )

        sections: list[dict[str, Any]] = []
        cards_by_section = {
            key: [c for c in (_card(session, p) for p in by_section.get(key, [])) if c.item_count > 0]
            for key, _, _ in _SECTION_ORDER
        }

        # Denní mixy mají vlastní řadu hned pod -- v Rychlém výběru jen jako
        # záloha, jinak "Denní mix 1" třikrát na první obrazovce (design audit #8).
        mixes = cards_by_section["mixes"]
        other_mixes = [c for c in mixes if not (c.source or "").startswith("personal:daily-mix:")]
        daily = [c for c in mixes if (c.source or "").startswith("personal:daily-mix:")]
        quick = (other_mixes + daily)[:3] + cards_by_section["charts"][:2] + cards_by_section["editorial"][:1]
        quick = quick[:6]
        if quick:
            sections.append({"id": "quick_picks", "title": "Rychlý výběr", "type": "quick_picks", "items": [c.model_dump(mode="json", by_alias=True) for c in quick]})

        # Žánry připnuté profilem (Profil › Žánry na Domů) -- tátův bluegrass.
        from app import browse
        from app.models import HomeSnapshot as _Snap

        for c in browse.pinned_genres(user_id):
            # Řada žánru a u bluegrassu i jeho novinky z posledního roku.
            for key, section_id, title in (
                (browse.rail_key(c.id), f"genre_{c.id}", c.title),
                (browse.new_key(c.id), f"genre_new_{c.id}", f"Novinky: {c.title}"),
            ):
                snap = session.get(_Snap, key)
                playlist_id = (snap.payload or {}).get("playlistId") if snap else None
                tracks = _playlist_tracks(session, playlist_id, 20) if playlist_id else []
                if tracks:
                    sections.append(
                        {
                            "id": section_id,
                            "title": title,
                            "type": "track_rail",
                            "playlistId": playlist_id,
                            "items": [t.model_dump(mode="json", by_alias=True) for t in tracks],
                        }
                    )

        worldwide = next((p for p in by_section.get("charts", []) if p.source == "deezer:playlist:3155776842"), None)
        for key, title, kind in _SECTION_ORDER:
            if key in ("new_releases", "top_albums"):
                snapshot = session.get(HomeSnapshot, key)
                albums = []
                for release_id in (snapshot.payload.get("releaseIds") if snapshot else None) or []:
                    release = session.get(Release, release_id)
                    if release is None:
                        continue
                    artist = session.get(Artist, release.artist_id)
                    albums.append(
                        AlbumCardOut(
                            id=release.id,
                            title=release.title,
                            artist_id=release.artist_id,
                            artist_name=artist.name if artist else None,
                            release_date=release.release_date,
                            release_type=release.release_type,
                            images=release.images or [],
                        ).model_dump(mode="json", by_alias=True)
                    )
                if albums:
                    sections.append({"id": key, "title": title, "type": kind, "items": albums})
                continue
            cards = cards_by_section.get(key) or []
            if cards:
                sections.append({"id": key, "title": title, "type": kind, "items": [c.model_dump(mode="json", by_alias=True) for c in cards]})
            if key == "charts" and worldwide is not None:
                tracks = _playlist_tracks(session, worldwide.id, 20)
                if tracks:
                    sections.append(
                        {
                            "id": "trending_tracks",
                            "title": "Populární ve světě",
                            "type": "track_rail",
                            "playlistId": worldwide.id,
                            "items": [t.model_dump(mode="json", by_alias=True) for t in tracks],
                        }
                    )
        return {"generatedAt": utcnow().isoformat(), "sections": sections}


async def get_home(user_id: str) -> dict[str, Any]:
    async def build() -> dict[str, Any]:
        # Osobní snapshoty (výběr kategorií...) tohoto profilu.
        token = g.set_home_user(user_id)
        try:
            return await asyncio.to_thread(build_home, user_id)
        finally:
            g.reset_home_user(token)

    return await cached_json(f"home:{user_id}", HOME_CACHE_TTL_S, build)
