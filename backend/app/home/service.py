"""`GET /home` + refresh smyčka generátorů (viz generators.py)."""

from __future__ import annotations

import asyncio
import logging
import os
from datetime import datetime, timedelta, timezone
from typing import Any, Awaitable, Callable

from sqlmodel import Session, select

from app.catalog.availability import compute_availability, recording_artist_name, resolve_artist_name
from app.catalog.cache import CACHE_PREFIX, cached_json_swr
from app.catalog.schemas import CamelModel, RecordingOut
from app.db import engine
from app.home import generators as g
from app.home import personal_mixes as pm
from app.models import GLOBAL_PLAYLIST_OWNER, Artist, HomeSnapshot, Playlist, PlaylistItem, PlaylistKind, Recording, Release
from app.redis_bus import get_redis
from app.utils import utcnow

logger = logging.getLogger(__name__)

HOME_CACHE_TTL_S = 5 * 60
# Nejstarší uložené Domů, které se ještě ukáže (a hned na pozadí obnoví).
HOME_KEEP_S = 60 * 60


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
    registry.append(("personal:styles", g.DAILY_TTL, pm.build_styles))
    from app.home import czech as czech_home

    registry.append(("personal:czech", timedelta(hours=12), czech_home.build_enabled))
    from app.home import extra_sections

    registry.append(("personal:extra-sections", timedelta(minutes=30), extra_sections.build_enabled))
    registry.append(("personal:popular-playlists", g.DAILY_TTL, pm.build_popular_playlists))
    from app import tags as _tags

    registry.append(("personal:warm-styles", g.DAILY_TTL, _tags.warm_style_pages))
    from app.home.warm_artists import warm_artist_pages

    registry.append(("personal:warm-artists", g.DAILY_TTL, warm_artist_pages))
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
    # Videoklipy -> oficiální audio (intro rozhodí synchronizované texty).
    from app.tools import upgrade_video_audio

    registry.append(("maintenance:video-audio", g.DAILY_TTL, lambda: upgrade_video_audio.run(40)))
    # Importované poslechy bez interpreta (Apple Music) -> dohledat, nezahazovat.
    from app.library import pending_plays

    registry.append(("maintenance:pending-imports", timedelta(minutes=30), pending_plays.run))
    # Historie hledání v slskd: starší než hodina pryč (nahromaděná rozbíjí
    # nová hledání), přehled se před smazáním uloží vedle DB.
    registry.append(("maintenance:slskd-searches", timedelta(hours=1), _prune_slskd_searches))
    # Herní / filmové soundtracky: živé řady (Steam, Wikidata, Apple plakáty).
    from app import soundtrack_discovery

    registry.append(("soundtracks:discovery", g.DAILY_TTL, soundtrack_discovery.build_all))
    return registry


async def _prune_slskd_searches() -> int:
    from pathlib import Path

    from app.providers import SlskdProvider

    if os.environ.get("MEDIA_PROVIDER", "composite") == "placeholder":
        return 0
    return await SlskdProvider().prune_searches(archive=Path("/data/db/slskd-search-history.jsonl"))


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
    for pattern in (f"{CACHE_PREFIX}home:*", f"{CACHE_PREFIX}swr:home:*"):
        async for key in redis.scan_iter(match=pattern):
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
                    # Typ chyby vždy -- timeout má prázdný text a log byl jen "selhal: ".
                    logger.warning("home: generátor %s selhal: %s: %s", label, type(exc).__name__, exc)
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
    from app.catalog.rate_limit import mark_background

    mark_background()  # dotazy ven až po tom, co právě otevřel uživatel
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
    ("category_mixes", "Tvoje mixy podle žánrů", "playlist_cards"),
    ("styles", "Prozkoumej své styly", "tag_chips"),
    ("czech", "Česká hudba", "genre_showcase"),
    ("popular_playlists", "Populární playlisty pro tebe", "deezer_playlists"),
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
    if source and source.startswith("personal:tag:"):
        # Mix stylu: barva českého žánru, jinak hlavního žánru stylu
        # (bluegrass -> Bluegrass, shoegaze -> Indie), jinak z názvu.
        from app.home.czech import CZECH_GENRES
        from app.tags import parent_genres

        tag = source[len("personal:tag:"):]
        for t_, _title, color in CZECH_GENRES.values():
            if t_ == tag:
                return color
        category = get_category(tag) or next((get_category(p) for p in parent_genres(tag)), None)
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
    if source.startswith("personal:tag:"):
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
        # Oblíbené mají v DB anglický název z importu ("Liked Songs").
        title="Oblíbené skladby" if playlist.source == "liked-songs" else playlist.title,
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
        artist_name=recording_artist_name(session, recording),
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
    from app.catalog.availability import prefetch_recordings

    _loaded = prefetch_recordings(session, [i.recording_id for i in items])  # noqa: F841
    out = []
    for item in items:
        recording = session.get(Recording, item.recording_id)
        if recording is not None:
            out.append(_recording_out(session, recording))
    return out


# Obecné styly, které jsou jen jiným názvem hlavního žánru (kategorie) --
# vedle "Tvůj mix · Folk / Akustická" se "Tvůj mix · Folk" neukazuje.
_STYLE_TO_CATEGORY = {
    "alternative": "indie", "indie": "indie", "indie rock": "indie", "folk": "folk", "acoustic": "folk",
    "singer-songwriter": "folk", "rock": "rock", "pop": "pop", "electronic": "electronic", "rap": "hiphop",
    "hip-hop": "hiphop", "hip hop": "hiphop", "blues": "blues", "jazz": "jazz", "metal": "metal",
    "heavy metal": "metal", "country": "country", "soul": "soul", "rnb": "rnb", "dance": "dance",
    "bluegrass": "bluegrass", "classical": "classical", "reggae": "reggae",
}


def _style_mix_cards(session: Session, user_id: str, shown_categories: set[str]) -> list:
    """Osobní mixy stylů profilu (Tvé styly, `personal:tag:<štítek>`) jako
    karty -- v pořadí síly stylu, bez těch, co jen jinak pojmenovávají už
    zobrazený hlavní žánr."""
    from app.home import personal_mixes as pm_
    from app.tags import slug

    snap = session.get(HomeSnapshot, pm_.styles_key(user_id))
    tags = list((snap.payload or {}).get("tags") or [])[:12] if snap else []
    cards = []
    for tag in tags:
        p = session.exec(
            select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == f"personal:tag:{slug(tag)}")
        ).first()
        if p is None:
            continue
        if _STYLE_TO_CATEGORY.get(slug(tag)) in shown_categories:
            continue
        card = _card(session, p)
        if card.item_count > 0:
            cards.append(card)
    return cards


def _quick_picks(session: Session, user_id: str, by_section, cards_by_section, other_mixes, daily) -> list:
    """Rychlý výběr: připnuté napřed (max 6), zbytek podle denní doby
    (app/home/quick_picks.py); bez historie původní pořadí."""
    from app.home import quick_picks as qp
    from app.library.spotify_import import get_or_create_liked_songs_playlist
    from app.models import PlaylistKind, PlaylistMember

    liked = get_or_create_liked_songs_playlist(session, user_id)
    # Připínání je v "Tvoje výběry" (app/home/picks.py), tady jen chytré pořadí.
    pinned: list = []
    room = qp.QUICK_SIZE
    taken = {c.id for c in pinned}
    fallback = (other_mixes + daily)[:3]
    # Kandidáti chytrého výběru: tvoje mixy, žánrové mixy, společné mixy,
    # tvoje playlisty a Oblíbené -- bez ohledu na to, co je na Domů skryté.
    candidates: list[Playlist] = []
    for key in ("mixes", "category_mixes", "blends"):
        candidates += by_section.get(key, [])
    candidates += session.exec(
        select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.kind == PlaylistKind.USER)
    ).all()
    candidates.append(liked)
    # Žebříčky a nálady soutěží taky, ale mají jen `qp.WIDE_SLOTS` míst -- a
    # jen když si je člověk na Domů zapnul. Dřív je dostal i nováček, který
    # je vypnuté má (rozpor s pravidlem "nic, co si nevybral"; audit 7. 10.).
    layout = get_layout(session, user_id)
    wide_keys = [key for key in ("charts", "editorial") if is_visible(layout, key)]
    wide = {p.id for key in wide_keys for p in by_section.get(key, [])}
    candidates += [p for key in wide_keys for p in by_section.get(key, [])]
    candidates = [p for p in {p.id: p for p in candidates}.values() if p.id not in taken]
    ranked = qp.rank(session, user_id, candidates, liked.id)
    auto: list = []
    wide_used = 0
    best_wide = None
    for p in ranked:
        if p.id in wide:
            if wide_used >= qp.WIDE_SLOTS:
                continue
            card = _card(session, p)
            if card.item_count == 0:
                continue
            if best_wide is None:
                best_wide = card
            if len(auto) >= room - qp.WIDE_SLOTS + wide_used:
                continue  # místo pro něj se drží až na konci
            auto.append(card)
            taken.add(card.id)
            wide_used += 1
            continue
        if len(auto) >= room - (qp.WIDE_SLOTS - wide_used):
            continue
        card = _card(session, p)
        if card.item_count > 0 and card.id not in taken:
            auto.append(card)
            taken.add(card.id)
    # Jedno místo mimo vlastní vkus: nejlépe sedící žebříček / nálada.
    if wide_used < qp.WIDE_SLOTS and best_wide is not None and best_wide.id not in taken:
        auto.append(best_wide)
        taken.add(best_wide.id)
    for card in fallback:
        if len(auto) >= room:
            break
        if card.id not in taken:
            auto.append(card)
            taken.add(card.id)
    return pinned + auto


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
        quick = _quick_picks(session, user_id, by_section, cards_by_section, other_mixes, daily)
        if quick:
            sections.append({"id": "quick_picks", "title": "Rychlý výběr", "type": "quick_picks", "items": [c.model_dump(mode="json", by_alias=True) for c in quick]})

        # Žánry připnuté profilem (Profil › Žánry na Domů) -- tátův bluegrass.
        from app import browse
        from app.models import HomeSnapshot as _Snap

        # Připnuté soundtracky (Herní soundtracky, Filmy a seriály) -- vitrína
        # z denního snímku, "Zobrazit vše" otevře celou stránku.
        from app import soundtrack_discovery as _sd

        for c in browse.pinned_soundtracks(user_id):
            items = _sd.showcase_items(session, c.id)
            if items:
                sections.append({"id": f"genre_{c.id}", "title": c.title, "type": "genre_showcase", "categoryId": c.id, "items": items})

        for c in browse.pinned_genres(user_id):
            # Vitrína žánru: mix napřed, pak novinky, alba a interpreti --
            # ukázka celé stránky žánru (dřív jen řada skladeb jednoho playlistu).
            showcase = session.get(_Snap, browse.showcase_key(c.id))
            items = browse.showcase_items(session, showcase.payload or {}) if showcase else []
            if len(items) >= 4:
                sections.append(
                    {"id": f"genre_{c.id}", "title": c.title, "type": "genre_showcase", "categoryId": c.id, "items": items}
                )
                continue
            # Vitrína ještě není (první hodina) -- řada žánru a novinky.
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

        # Připnuté české žánry (Profil › Domů › Žánry) -- vitríny jako u žánrů.
        from app.home import czech as _cz

        for gid in _cz.pinned(user_id):
            sec = _cz.render(session, user_id, gid)
            if sec:
                sections.append(sec)

        worldwide = next((p for p in by_section.get("charts", []) if p.source == "deezer:playlist:3155776842"), None)
        for key, title, kind in _SECTION_ORDER:
            if key == "czech":
                from app.home import czech as cz

                sec = cz.render(session, user_id, "cz")
                if sec:
                    sections.append(sec)
                continue
            if key == "category_mixes":
                # Mixy hlavních žánrů ("Tvůj mix · Folk") a pak tvých stylů
                # ("Tvůj mix · Bluegrass") -- mění se podle toho, co posloucháš.
                # Štítky stylů (sekce "styles") otevírají celou stránku stylu.
                cards = list(cards_by_section.get("category_mixes") or [])
                shown = {(c.source or "").rsplit(":", 1)[-1] for c in cards}
                cards += _style_mix_cards(session, user_id, shown)
                if cards:
                    sections.append({"id": key, "title": title, "type": kind, "items": [c.model_dump(mode="json", by_alias=True) for c in cards]})
                continue
            if key == "styles":
                # Tvé styly (štítky Last.fm tvých interpretů, podle toho, co
                # posloucháš teď) -> stránky stylů. Jiná funkce než "Tvoje
                # žánry" (osobní mixy hlavních žánrů) -- uživatel je chce zvlášť.
                snap = session.get(HomeSnapshot, pm.styles_key(user_id))
                tags = (snap.payload or {}).get("tags") if snap else None
                if tags:
                    from app.tags import title_of

                    sections.append(
                        {"id": "styles", "title": title, "type": "tag_chips", "items": [{"tag": t, "title": title_of(t)} for t in tags]}
                    )
                continue
            if key == "popular_playlists":
                snap = session.get(HomeSnapshot, pm.popular_playlists_key(user_id))
                items = (snap.payload or {}).get("items") if snap else None
                if items:
                    sections.append({"id": key, "title": title, "type": kind, "items": items})
                continue
            if key == "genres":
                # Žánry na Domů = PŘESNĚ dlaždice z Hledat (stejné názvy, barvy,
                # ikony, otevřou stejnou stránku žánru) -- dřív karty playlistů.
                from app.browse import list_categories

                tiles = [c for c in list_categories() if c["group"] == "genre"]
                if tiles:
                    sections.append({"id": "genres", "title": title, "type": "category_tiles", "items": tiles})
                continue
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
        # Volitelné sekce (Profil › Domů) -- jen zapnuté, ze snapshotů.
        from app.home import extra_sections as xs

        from app.home.picks import RAILS

        layout = get_layout(session, user_id)
        for spec in xs.SPECS:
            if spec.id not in RAILS and is_visible(layout, spec.id):
                try:
                    sections += xs.render(session, user_id, spec.id)
                except Exception:  # noqa: BLE001 - jedna sekce nesmí shodit Domů
                    logger.exception("sekce %s se nepodařilo vykreslit", spec.id)

        picks_section = _picks_section(session, user_id, worldwide)
        if picks_section:
            sections.append(picks_section)

        # "Pokračovat v poslechu" skládá klient (`/home/recent`) -- tady jen
        # zástupce, ať jde řadit a skrýt jako ostatní sekce.
        sections.insert(0, {"id": "continue", "title": "Pokračovat v poslechu", "type": "continue", "items": []})
        return {"generatedAt": utcnow().isoformat(), "sections": apply_layout(session, user_id, sections)}


def layout_key(user_id: str) -> str:
    return f"home_layout:{user_id}"


# Výchozí stav: základní sada zapnutá, ostatní (a všechny nové sekce) si
# profil zapne sám v Profil › Domů -- ať si každý dá přesně, co mu přináší.
DEFAULT_OFF = {
    # Žebříčky, novinky a česká hudba nováčka postrkují k cizímu vkusu --
    # zapne si je sám (uživatel 4. 10. 2026; stávající profily mají
    # rozložení uložené, nezmění se).
    "charts", "new_releases", "czech",
    "years", "trending_tracks", "top_albums", "genres", "editorial", "popular_playlists",
    "now_mix", "year_ago", "forgotten", "unfinished", "anniversaries", "release_radar", "deep_cuts",
    "artist_discovery", "album_picks", "shazam", "soundcloud", "family",
}


def get_layout(session: Session, user_id: str) -> dict[str, Any]:
    """{"order": [...], "visible": {id: bool}} -- jen to, co profil sám změnil."""
    row = session.get(HomeSnapshot, layout_key(user_id))
    payload = (row.payload or {}) if row else {}
    visible = dict(payload.get("visible") or {})
    for sid in payload.get("hidden") or []:  # starší tvar (jen skryté)
        visible.setdefault(sid, False)
    return {"order": list(payload.get("order") or []), "visible": visible}


def is_visible(layout: dict[str, Any], section_id: str) -> bool:
    return bool(layout["visible"].get(section_id, section_id not in DEFAULT_OFF))


def section_enabled(user_id: str, section_id: str) -> bool:
    from app.home import picks

    with Session(engine) as session:
        # Chytrý seznam se generuje, když je připnutý v "Tvoje výběry".
        if section_id in picks.RAILS:
            return f"rail:{section_id}" in picks.get(session, user_id)
        return is_visible(get_layout(session, user_id), section_id)


def _layout_id(section_id: str) -> str:
    # "Novinky: žánr" patří ke svému žánru, "X poslouchá" k sekci rodiny.
    if section_id.startswith("genre_new_"):
        return "genre_" + section_id[len("genre_new_"):]
    if section_id.startswith("family_"):
        return "family"
    return section_id


def default_entries(user_id: str, include_rails: bool = False) -> list[tuple[str, str]]:
    """Všechny sekce Domů ve výchozím pořadí (id, název). Chytré seznamy
    (`picks.RAILS`) už nejsou sekce -- připínají se do "Tvoje výběry"."""
    from app import browse
    from app.home.extra_sections import SPECS
    from app.home.picks import RAILS

    if not include_rails:
        return [e for e in default_entries(user_id, include_rails=True) if e[0] not in RAILS]
    extra = {s.id: s.title for s in SPECS}
    out: list[tuple[str, str]] = [
        ("continue", "Pokračovat v poslechu"),
        ("quick_picks", "Rychlý výběr"),
        ("track_mixes", TRACK_MIXES_TITLE),
    ]
    if "now_mix" in extra:
        out.append(("now_mix", extra["now_mix"]))
    out += [(f"genre_{c.id}", c.title) for c in browse.pinned_genres(user_id)]
    out += [(f"genre_{c.id}", c.title) for c in browse.pinned_soundtracks(user_id)]
    from app.home import czech as _cz

    out += [(_cz.section_id(gid), _cz.CZECH_GENRES[gid][1]) for gid in _cz.pinned(user_id)]
    for key, title, _kind in _SECTION_ORDER:
        out.append((key, title))
        follow = {
            "mixes": ["year_ago", "forgotten", "unfinished", "anniversaries"],
            "styles": ["deep_cuts", "artist_discovery", "album_picks"],
            "charts": ["trending_tracks"],
            "new_releases": ["release_radar"],
            "editorial": ["shazam", "soundcloud", "family"],
        }.get(key, [])
        for sid in follow:
            out.append((sid, "Populární ve světě" if sid == "trending_tracks" else extra.get(sid, sid)))
    return out


def effective_order(user_id: str, layout: dict[str, Any], include_rails: bool = False) -> list[str]:
    """Uložené pořadí + sekce, které v něm nejsou (nové), za svého
    výchozího předchůdce."""
    defaults = [sid for sid, _t in default_entries(user_id, include_rails=include_rails)]
    order = [sid for sid in layout["order"] if sid in defaults]
    if not order:
        return defaults
    for i, sid in enumerate(defaults):
        if sid in order:
            continue
        prev = next((defaults[j] for j in range(i - 1, -1, -1) if defaults[j] in order), None)
        order.insert(order.index(prev) + 1 if prev else 0, sid)
    return order


def apply_layout(session: Session, user_id: str, sections: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Pořadí a skrytí sekcí podle profilu (Profil › Domů)."""
    layout = get_layout(session, user_id)
    pos = {sid: i for i, sid in enumerate(effective_order(user_id, layout))}
    visible = [s for s in sections if is_visible(layout, _layout_id(s["id"]))]
    ordered = [s for _p, _i, s in sorted(((pos.get(_layout_id(s["id"]), 10_000), i, s) for i, s in enumerate(visible)), key=lambda k: (k[0], k[1]))]
    return _collapse_track_rails(session, user_id, ordered)


TRACK_MIXES_TITLE = "Tvoje výběry"


def _collapse_track_rails(session: Session, user_id: str, sections: list[dict[str, Any]]) -> list[dict[str, Any]]:
    """Zbylé sekce se seznamem skladeb (řada žánru, než je hotová vitrína)
    -- roztažené seznamy se na mobilu nedají ovládat, takže karta playlistu
    na stejném místě."""
    out: list[dict[str, Any]] = []
    for sec in sections:
        if sec.get("type") != "track_rail":
            out.append(sec)
            continue
        playlist_id = sec.get("playlistId") or _rail_playlist(session, user_id, sec)
        playlist = session.get(Playlist, playlist_id) if playlist_id else None
        if playlist is None:
            continue
        card = _card(session, playlist).model_copy(update={"title": sec["title"]})
        if card.item_count > 0:
            out.append({"id": sec["id"], "title": sec["title"], "type": "playlist_cards", "items": [card.model_dump(mode="json", by_alias=True)]})
    session.commit()
    return out


def _rail_sections(session: Session, user_id: str, rail: str, worldwide: Playlist | None) -> list[dict[str, Any]]:
    """Chytrý seznam -> seznam(y) skladeb (rodina = jeden za člověka)."""
    if rail == "trending_tracks":
        if worldwide is None:
            return []
        tracks = _playlist_tracks(session, worldwide.id, 50)
        return [{"id": "trending_tracks", "title": "Populární ve světě", "items": [t.model_dump(mode="json", by_alias=True) for t in tracks]}]
    from app.home import extra_sections as xs

    try:
        return xs.render(session, user_id, rail)
    except Exception:  # noqa: BLE001 - jeden seznam nesmí shodit Domů
        logger.exception("chytrý seznam %s se nepodařilo vykreslit", rail)
        return []


def _picks_section(session: Session, user_id: str, worldwide: Playlist | None) -> dict[str, Any] | None:
    """"Tvoje výběry" = připnuté playlisty, alba a chytré seznamy v pořadí
    připnutí (app/home/picks.py)."""
    from app import browse
    from app.home import picks
    from app.library.spotify_import import get_or_create_liked_songs_playlist
    from app.models import PlaylistMember

    liked_id = get_or_create_liked_songs_playlist(session, user_id).id
    items: list[dict[str, Any]] = []
    for pin in picks.get(session, user_id):
        kind, _, ref = pin.partition(":")
        if kind == "playlist":
            p = session.get(Playlist, ref)
            if p is None:
                continue
            member = session.exec(
                select(PlaylistMember).where(PlaylistMember.playlist_id == p.id, PlaylistMember.user_id == user_id)
            ).first()
            if p.id != liked_id and p.owner_user_id not in (user_id, GLOBAL_PLAYLIST_OWNER) and member is None:
                continue
            card = _card(session, p)
            if card.item_count > 0:
                items.append({"itemType": "playlist", **card.model_dump(mode="json", by_alias=True)})
        elif kind == "album":
            release = session.get(Release, ref)
            if release is not None:
                items.append({"itemType": "album", "badge": None, **browse._album_card(session, release)})
        elif kind == "rail":
            for sec in _rail_sections(session, user_id, ref, worldwide):
                pid = _rail_playlist(session, user_id, sec)
                p = session.get(Playlist, pid) if pid else None
                if p is None:
                    continue
                card = _card(session, p).model_copy(update={"title": sec["title"]})
                if card.item_count > 0:
                    items.append({"itemType": "playlist", **card.model_dump(mode="json", by_alias=True)})
    session.commit()
    if not items:
        return None
    return {"id": "track_mixes", "title": TRACK_MIXES_TITLE, "type": "genre_showcase", "items": items}


def _rail_playlist(session: Session, user_id: str, sec: dict[str, Any]) -> str | None:
    """Sekce bez vlastního playlistu (Shazam, Před rokem...) -> playlist
    profilu `home:rail:<id>`, ať jde otevřít celá (Přehrát, Zamíchat).
    Položky se přepíšou jen při změně."""
    from app.library.dislikes import without_disliked

    ids = without_disliked(user_id, [i["id"] for i in sec.get("items") or [] if i.get("id")])
    if not ids:
        return None
    source = f"home:rail:{sec['id']}"
    playlist = session.exec(select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source == source)).first()
    if playlist is None:
        playlist = Playlist(
            owner_user_id=user_id, title=sec["title"], kind=PlaylistKind.GENERATED_RECOMMENDATION, source=source
        )
        session.add(playlist)
        session.flush()
    current = [
        i.recording_id
        for i in session.exec(
            select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id).order_by(PlaylistItem.position)
        ).all()
    ]
    if current != ids or playlist.title != sec["title"]:
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all():
            session.delete(item)
        for pos, rid in enumerate(ids):
            session.add(PlaylistItem(playlist_id=playlist.id, recording_id=rid, position=pos))
        playlist.title = sec["title"]
        playlist.cover_urls = []
        playlist.generated_at = utcnow()
        session.add(playlist)
    return playlist.id


def layout_entries(user_id: str) -> list[dict[str, Any]]:
    """Všechny sekce Domů v pořadí profilu, i se skrytými (Profil › Domů)."""
    titles = dict(default_entries(user_id))
    with Session(engine) as session:
        layout = get_layout(session, user_id)
    return [
        {"id": sid, "title": titles.get(sid, sid), "visible": is_visible(layout, sid)}
        for sid in effective_order(user_id, layout)
    ]


async def get_home(user_id: str) -> dict[str, Any]:
    async def build() -> dict[str, Any]:
        # Osobní snapshoty (výběr kategorií...) tohoto profilu.
        token = g.set_home_user(user_id)
        try:
            return await asyncio.to_thread(build_home, user_id)
        finally:
            g.reset_home_user(token)

    # Hned z uložené verze, starší než 5 min se obnoví na pozadí (dřív se
    # při prvním načtení čekalo na sestavení -- s víc lidmi naráz až 10 s).
    return await cached_json_swr(f"home:{user_id}", HOME_CACHE_TTL_S, build, keep_seconds=HOME_KEEP_S)
