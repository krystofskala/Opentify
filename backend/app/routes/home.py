"""`GET /home` -- celá obrazovka Domů jedním voláním ze snapshotů v DB."""

from __future__ import annotations

import asyncio
from datetime import timezone

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select

from app.auth import get_current_user, require_admin
from app.catalog.availability import recording_artist_name, resolve_artist_name
from app.db import engine, get_session
from app.home.generators import _covers_for
from app.models import Artist, Listen, Playlist, PlaylistItem, Recording, Release
from app.library.spotify_history import IMPORTED_SOURCES
from app.home.service import _accent_for, _art_style, get_home, run_generators

home_router = APIRouter(prefix="/home", tags=["home"])


@home_router.get("")
async def home(current: tuple[str, str] = Depends(get_current_user)):
    user_id, _device_id = current
    data = await get_home(user_id)
    from app.home import impressions

    asyncio.get_running_loop().run_in_executor(None, impressions.record, user_id, data)
    return data


class PlayNowIn(BaseModel):
    seedIds: list[str] = []  # co právě hrálo (nekonečné hraní); prázdné = Pusť teď
    playedIds: list[str] = []  # už ve frontě / zahrané v téhle session
    size: int = 8
    # Čip nálady (klid / energie / soustredeni / melancholie / party / prekvap).
    mood: str | None = None
    # „Z čeho mám začít?“ (profil bez poslechů): interpret nebo skladba.
    startArtistId: str | None = None
    startRecordingId: str | None = None


@home_router.get("/play-now/moods")
def play_now_moods(_current=Depends(get_current_user)):
    """Čipy nálad pro Pusť teď (pořadí = jak se ukážou)."""
    from app.home.play_now import MOODS

    return {"moods": [{"id": k, "title": v[2]} for k, v in MOODS.items()]}


@home_router.post("/play-now")
async def play_now(body: PlayNowIn, current: tuple[str, str] = Depends(get_current_user)):
    """Další várka pro "Pusť teď" / nekonečné hraní (app/home/play_now.py)."""
    from app.home import play_now as pn
    from app.home.service import _recording_out

    size = max(1, min(body.size, 20))
    if body.startArtistId or body.startRecordingId:
        # „Z čeho mám začít?“ (profil bez dat): navázat na zadaného interpreta
        # nebo skladbu -- jeho top skladby napřed, pak podobné.
        chunk = await pn.start_from(current[0], body.startArtistId, body.startRecordingId, size)
    else:
        chunk = await pn.next_chunk(current[0], body.seedIds[-5:], body.playedIds[-300:], size, body.mood)
    with Session(engine) as session:
        tracks = [
            _recording_out(session, rec).model_dump(mode="json", by_alias=True)
            for rec in (session.get(Recording, rid) for rid in chunk["recordingIds"])
            if rec is not None
        ]
    needs_start = False
    if not tracks and not body.seedIds:
        from app.home.service import has_taste_data

        with Session(engine) as session:
            needs_start = not has_taste_data(session, current[0])
    return {"tracks": tracks, "reason": chunk["reason"], "needsStart": needs_start}


@home_router.get("/rec-report")
def rec_report(days: int = 7, _admin=Depends(require_admin)):
    """Měření doporučování po profilech (app/rec_log.py) -- jen správce."""
    from app import rec_log

    return {"days": days, "profiles": rec_log.report(max(1, min(days, 90)))}


class FeedbackIn(BaseModel):
    direction: str  # "more" | "less"
    artistId: str | None = None
    recordingId: str | None = None  # stačí skladba -- vezme se její interpret


@home_router.post("/feedback")
def taste_feedback(body: FeedbackIn, current: tuple[str, str] = Depends(get_current_user)):
    """"Víc / míň takových" (app/home/feedback.py)."""
    from app.home import feedback

    if body.direction not in ("more", "less"):
        raise HTTPException(status_code=400, detail="směr musí být more nebo less")
    artist_id = body.artistId or (feedback.artist_for(body.recordingId) if body.recordingId else None)
    if not artist_id:
        raise HTTPException(status_code=404, detail="interpret nenalezen")
    with Session(engine) as session:
        if session.get(Artist, artist_id) is None:
            raise HTTPException(status_code=404, detail="interpret nenalezen")
    delta = feedback.set_feedback(current[0], artist_id, body.direction)
    return {"artistId": artist_id, "delta": delta}


@home_router.delete("/feedback/{artist_id}")
def clear_taste_feedback(artist_id: str, current: tuple[str, str] = Depends(get_current_user)):
    from app.home import feedback

    feedback.clear(current[0], artist_id)
    return {"artistId": artist_id, "delta": 0}


@home_router.get("/feedback")
def list_taste_feedback(current: tuple[str, str] = Depends(get_current_user)):
    from app.home import feedback

    return {"artists": feedback.deltas(current[0])}


@home_router.get("/why/{recording_id}")
async def why_this(recording_id: str, current: tuple[str, str] = Depends(get_current_user)):
    """"Proč tohle?" -- jen na vyžádání, jemný důvod bez čísel (app/home/why.py)."""
    from app.home.why import reason

    return {"recordingId": recording_id, "reason": await asyncio.to_thread(reason, current[0], recording_id)}


@home_router.get("/discoveries")
async def discoveries(current: tuple[str, str] = Depends(get_current_user)):
    """Profil › Objevy: kolik nových skladeb tě chytlo a odkud (app/home/discoveries.py)."""
    from app.catalog.cache import cached_json
    from app.home.discoveries import report
    from app.home.service import _recording_out

    user_id = current[0]
    data = await cached_json(f"discoveries:v1:{user_id}", 30 * 60, lambda: asyncio.to_thread(report, user_id))

    def tracks() -> list[dict]:
        with Session(engine) as session:
            out = []
            for item in data["recentCaught"]:
                rec = session.get(Recording, item["recordingId"])
                if rec is not None:
                    out.append(
                        {
                            **_recording_out(session, rec).model_dump(mode="json", by_alias=True),
                            "discoverySource": item["source"],
                        }
                    )
            return out

    return {**{k: v for k, v in data.items() if k != "recentCaught"}, "recentCaught": await asyncio.to_thread(tracks)}


@home_router.get("/history")
def history(
    limit: int = 100,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Profil › Historie: posledních `limit` poslechů profilu v appce,
    nejnovější první, i opakované skladby. Importy z jiných služeb ne (staré
    poslechy jinde). "Puštěné" = poslech (polovina / 4 min), ne každé
    rozehrání -- přeskočené skladby by historii zahltily."""
    from app.home.service import _recording_out

    user_id, _device_id = current
    limit = max(1, min(limit, 200))
    listens = session.exec(
        select(Listen)
        .where(Listen.user_id == user_id, (Listen.source.is_(None)) | (Listen.source.notin_(IMPORTED_SOURCES)))  # type: ignore[union-attr]
        .order_by(Listen.played_at.desc())  # type: ignore[attr-defined]
        .limit(limit)
    ).all()
    outs: dict[str, dict] = {}
    items = []
    for listen in listens:
        if listen.recording_id not in outs:
            recording = session.get(Recording, listen.recording_id)
            if recording is None:
                continue
            outs[listen.recording_id] = _recording_out(session, recording).model_dump(mode="json", by_alias=True)
        played = listen.played_at
        items.append(
            {
                **outs[listen.recording_id],
                "playedAt": (played if played.tzinfo else played.replace(tzinfo=timezone.utc)).isoformat(),
                "playedFrom": listen.source,
            }
        )
    return {"items": items}


@home_router.get("/recent")
def recent(
    limit: int = 8,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """"Pokračovat v poslechu" nahoře na Domů -- poslední poslouchaná alba
    (u skladby bez alba skladba sama), nejnovější první. Z uložených
    poslechů, takže přežije obnovení stránky i jiné zařízení (dřív jen
    paměť klienta). Necachuje se -- má reagovat hned."""
    user_id, _device_id = current
    listens = session.exec(
        select(Listen)
        # Importovaná historie ze Spotify sem nepatří -- jen co hrálo v appce.
        .where(Listen.user_id == user_id, (Listen.source.is_(None)) | (Listen.source.notin_(IMPORTED_SOURCES)))  # type: ignore[union-attr]
        .order_by(Listen.played_at.desc())  # type: ignore[attr-defined]
        .limit(300)
    ).all()
    items: list[dict] = []
    seen: set[str] = set()
    for listen in listens:
        recording = session.get(Recording, listen.recording_id)
        if recording is None:
            continue
        # Přehráno z playlistu / Oblíbených / interpreta -> ta položka celá,
        # ne jednotlivé album skladby.
        context_item = _context_item(session, listen.context, user_id)
        if context_item is not None:
            key = f"c:{context_item['kind']}:{context_item['id']}"
            if key not in seen:
                seen.add(key)
                items.append(context_item)
            if len(items) >= limit:
                break
            continue
        release = session.get(Release, recording.release_id) if recording.release_id else None
        key = f"r:{release.id}" if release else f"t:{recording.id}"
        if key in seen:
            continue
        seen.add(key)
        artist_name = recording_artist_name(session, recording)
        if release is not None:
            image = release.images[0] if release.images else None
            items.append(
                {
                    "kind": "album",
                    "id": release.id,
                    "title": release.title,
                    "artistName": artist_name,
                    "imageUrl": image,
                    "lastRecordingId": recording.id,
                }
            )
        else:
            artist = session.get(Artist, recording.artist_id) if recording.artist_id else None
            items.append(
                {
                    "kind": "track",
                    "id": recording.id,
                    "title": recording.title,
                    "artistName": artist_name,
                    "imageUrl": artist.images[0] if artist and artist.images else None,
                    "lastRecordingId": recording.id,
                    "artistId": recording.artist_id,
                }
            )
        if len(items) >= limit:
            break
    return items


def _context_item(session: Session, context: str | None, user_id: str) -> dict | None:
    """Položka "Pokračovat v poslechu" z cesty, odkud se hrálo; `None` pro
    alba (řeší volající) a kontexty bez vlastní stránky (Domů, Hledat).
    Playlist jen takový, který profil smí číst (vlastní, člen, globální)."""
    if not context:
        return None
    parts = context.strip("/").split("/")
    if parts[:2] == ["library", "liked"]:
        return {"kind": "liked", "id": "liked", "title": "Oblíbené skladby", "artistName": "Playlist", "imageUrl": None}
    if len(parts) != 2:
        return None
    kind, ident = parts
    if kind == "playlists":
        from fastapi import HTTPException as _Http

        from app.routes.playlists import _readable_playlist_or_404

        try:
            playlist = _readable_playlist_or_404(session, ident, user_id)
        except _Http:
            return None
        ids = session.exec(
            select(PlaylistItem.recording_id)
            .where(PlaylistItem.playlist_id == playlist.id)
            .order_by(PlaylistItem.position)  # type: ignore[arg-type]
            .limit(40)
        ).all()
        covers = list(playlist.cover_urls or []) or _covers_for(list(ids))
        return {
            "kind": "playlist",
            "id": playlist.id,
            "title": playlist.title,
            "artistName": "Playlist",
            "imageUrl": covers[0] if covers else None,
            "imageUrls": covers[:4],
            "source": playlist.source,
            # Stejný generativní obal jako karta na Domů (design audit #1).
            "accentColor": _accent_for(playlist.source),
            "artStyle": _art_style(playlist.source),
        }
    if kind == "artists":
        artist = session.get(Artist, ident)
        if artist is None:
            return None
        return {
            "kind": "artist",
            "id": artist.id,
            "title": artist.name,
            "artistName": "Interpret",
            "imageUrl": artist.images[0] if artist.images else None,
        }
    return None


class HomeGenresIn(BaseModel):
    ids: list[str]


@home_router.get("/genres")
def home_genres(current: tuple[str, str] = Depends(get_current_user)):
    """Žánry na výběr pro řady na Domů a ty, co má profil připnuté."""
    from app import browse

    from app.home import czech

    return {
        "available": [
            {"id": c.id, "title": c.title, "color": c.color} for c in browse.CATEGORIES if c.group == "genre"
        ],
        "moods": [{"id": c.id, "title": c.title, "color": c.color} for c in browse.CATEGORIES if c.group == "mood"],
        "soundtracks": [
            {"id": c.id, "title": c.title, "color": c.color}
            for c in browse.CATEGORIES
            if c.group == "soundtrack" and c.parent is None
        ],
        # Česká hudba po žánrech (vitríny ze štítků Last.fm "czech rock"...).
        "czech": [
            {"id": gid, "title": title, "color": color}
            for gid, (_tag, title, color) in czech.CZECH_GENRES.items()
            if gid != "cz"
        ],
        "selected": [c.id for c in browse.pinned_genres(current[0])]
        + [c.id for c in browse.pinned_soundtracks(current[0])]
        + czech.pinned(current[0]),
    }


@home_router.put("/genres")
async def set_home_genres(body: HomeGenresIn, current: tuple[str, str] = Depends(get_current_user)):
    from app import browse
    from app.home.service import invalidate_home_cache
    from app.models import AppUser

    from app.home import czech

    ids = [
        i for i in dict.fromkeys(body.ids)
        if ((c := browse.get_category(i)) is not None and (c.group in ("genre", "mood") or (c.group == "soundtrack" and c.parent is None)))
        or (i in czech.CZECH_GENRES and i != "cz")
    ]
    with Session(engine) as session:
        user = session.get(AppUser, current[0])
        if user is not None:
            user.home_genres = ids
            session.add(user)
            session.commit()

    async def warm() -> None:
        for i in ids:
            if i in czech.CZECH_GENRES:
                try:
                    await czech.build_one(i, current[0])  # česká vitrína hned
                except Exception:  # noqa: BLE001
                    pass
                continue
            c = browse.get_category(i)
            if c is not None and c.group == "soundtrack":
                from app import soundtrack_discovery

                try:
                    await soundtrack_discovery.write_showcase(c.id)  # vitrína z denního snímku hned
                except Exception:  # noqa: BLE001
                    pass
                continue
            if c is not None:
                await browse.genre_rail(c)
                await browse.genre_new_releases(c)  # novinky (bluegrass) hned, ne až za hodinu
                try:
                    await browse.build_showcase(c)  # vitrína žánru na Domů hned
                except Exception:  # noqa: BLE001
                    pass
        await invalidate_home_cache()

    asyncio.create_task(warm())
    await invalidate_home_cache()
    return {"selected": ids}


def _pin_target(session: Session, user_id: str, playlist_id: str) -> str:
    """'liked' = Oblíbené profilu; jinak playlist, který profil vidí."""
    from app.library.spotify_import import get_or_create_liked_songs_playlist
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistMember

    if playlist_id == "liked":
        return get_or_create_liked_songs_playlist(session, user_id).id
    p = session.get(Playlist, playlist_id)
    if p is None:
        raise HTTPException(status_code=404, detail="playlist neexistuje")
    member = session.exec(
        select(PlaylistMember).where(PlaylistMember.playlist_id == p.id, PlaylistMember.user_id == user_id)
    ).first()
    if p.owner_user_id not in (user_id, GLOBAL_PLAYLIST_OWNER) and member is None:
        raise HTTPException(status_code=403, detail="cizí playlist")
    return p.id


@home_router.get("/quick-pins")
def quick_pins(current: tuple[str, str] = Depends(get_current_user)):
    """Připnuté do "Tvoje výběry": playlisty (i karty chytrých seznamů
    `home:rail:*`), alba a chytré seznamy, které jde ještě připnout."""
    from app.home import picks
    from app.library.spotify_import import get_or_create_liked_songs_playlist

    user_id = current[0]
    with Session(engine) as session:
        items = picks.get(session, user_id)
        liked = get_or_create_liked_songs_playlist(session, user_id).id
        rails = {i.split(":", 1)[1] for i in items if i.startswith("rail:")}
        rail_playlists = [
            p.id
            for p in session.exec(
                select(Playlist).where(Playlist.owner_user_id == user_id, Playlist.source.startswith("home:rail:"))  # type: ignore[union-attr]
            ).all()
            if picks.rail_of_source(p.source) in rails
        ]
    return {
        "ids": [i.split(":", 1)[1] for i in items if i.startswith("playlist:")] + rail_playlists,
        "albumIds": [i.split(":", 1)[1] for i in items if i.startswith("album:")],
        "rails": [{"id": sid, "title": title, "pinned": sid in rails} for sid, title in picks.RAILS.items()],
        "likedId": liked,
        "max": picks.MAX_PINS,
    }


def _pin_key(session: Session, user_id: str, kind: str, target_id: str) -> str:
    from app.home import picks

    if kind == "album":
        if session.get(Release, target_id) is None:
            raise HTTPException(status_code=404, detail="album neexistuje")
        return f"album:{target_id}"
    if kind == "rail":
        if target_id not in picks.RAILS:
            raise HTTPException(status_code=404, detail="neznámý seznam")
        return f"rail:{target_id}"
    pid = _pin_target(session, user_id, target_id)
    # Karta chytrého seznamu (playlist home:rail:*) = ten chytrý seznam.
    rail = picks.rail_of_source((session.get(Playlist, pid) or Playlist(owner_user_id="", title="")).source)
    return f"rail:{rail}" if rail else f"playlist:{pid}"


@home_router.put("/quick-pins/{target_id}")
async def pin_quick(target_id: str, kind: str = "playlist", current: tuple[str, str] = Depends(get_current_user)):
    from app.home import picks
    from app.home.service import invalidate_home_cache

    with Session(engine) as session:
        pin = _pin_key(session, current[0], kind, target_id)
        items = picks.get(session, current[0])
        if pin not in items:
            if len(items) >= picks.MAX_PINS:
                raise HTTPException(status_code=409, detail=f"Připnout jde nejvýš {picks.MAX_PINS} položek.")
            items = picks.save(session, current[0], [*items, pin])
    if pin.startswith("rail:"):
        # Chytrý seznam se generuje jen připnutý -- postavit hned.
        from app.home import extra_sections as xs

        sid = pin.split(":", 1)[1]
        if any(s.id == sid and s.build is not None for s in xs.SPECS):
            await xs.build_now(current[0], [sid], force=True)
    await invalidate_home_cache()
    return {"items": items}


@home_router.delete("/quick-pins/{target_id}")
async def unpin_quick(target_id: str, kind: str = "playlist", current: tuple[str, str] = Depends(get_current_user)):
    from app.home import picks
    from app.home.service import invalidate_home_cache

    with Session(engine) as session:
        pin = _pin_key(session, current[0], kind, target_id)
        items = picks.save(session, current[0], [i for i in picks.get(session, current[0]) if i != pin])
    await invalidate_home_cache()
    return {"items": items}


class HomeLayoutIn(BaseModel):
    order: list[str]
    hidden: list[str] = []
    # Podoba sekcí s volbou ({"album_picks": "row" | "one"}).
    modes: dict[str, str] = {}


class NewcomerDismissIn(BaseModel):
    card: str  # import | customize
    undo: bool = False


@home_router.post("/newcomer/dismiss")
async def newcomer_dismiss(body: NewcomerDismissIn, current: tuple[str, str] = Depends(get_current_user)):
    """„Teď ne“ u karet nováčka na Domů (a „Vrátit“ = undo)."""
    from app.home.service import invalidate_home_cache_for, layout_key
    from app.models import HomeSnapshot
    from app.utils import utcnow

    if body.card not in ("import", "customize"):
        raise HTTPException(status_code=400, detail="Neznámá karta.")
    with Session(engine) as session:
        row = session.get(HomeSnapshot, layout_key(current[0])) or HomeSnapshot(key=layout_key(current[0]), payload={})
        payload = dict(row.payload or {})
        dismissed = set(payload.get("dismissed") or [])
        if body.undo:
            dismissed.discard(body.card)
        else:
            dismissed.add(body.card)
        payload["dismissed"] = sorted(dismissed)
        row.payload = payload
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    await invalidate_home_cache_for(current[0])
    return {"dismissed": sorted(dismissed)}


@home_router.get("/layout")
def home_layout(current: tuple[str, str] = Depends(get_current_user)):
    """Sekce Domů v pořadí profilu, i se skrytými (Domů › Upravit)."""
    from app.home.service import layout_entries

    return {"sections": layout_entries(current[0])}


@home_router.put("/layout")
async def set_home_layout(body: HomeLayoutIn, current: tuple[str, str] = Depends(get_current_user)):
    from app.home.service import DISPLAY_MODES, invalidate_home_cache, layout_entries, layout_key
    from app.models import HomeSnapshot
    from app.utils import utcnow

    before = {e["id"]: e["visible"] for e in layout_entries(current[0])}
    known = set(before)
    order = [i for i in dict.fromkeys(body.order) if i in known]
    hidden = {i for i in body.hidden if i in known}
    # Prázdné pořadí = "Výchozí" (vše zpět, i zapnutí/vypnutí).
    visible = {sid: sid not in hidden for sid in known} if order else {}
    with Session(engine) as session:
        row = session.get(HomeSnapshot, layout_key(current[0])) or HomeSnapshot(key=layout_key(current[0]))
        # Zavřené karty nováčka (Import / Uprav Domů) se úpravou nesmažou.
        display = {sid: m for sid, m in body.modes.items() if m in DISPLAY_MODES.get(sid, ())} if order else {}
        row.payload = {
            "order": order, "visible": visible, "display": display,
            "dismissed": list((row.payload or {}).get("dismissed") or []),
        }
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    # Právě zapnuté nové sekce sestavit hned, ne až při dalším běhu.
    turned_on = [sid for sid, on in visible.items() if on and not before.get(sid)]
    if "czech" in turned_on:
        from app.home import czech

        asyncio.create_task(czech.build_one("cz", current[0]))
    if turned_on:
        from app.home import extra_sections

        asyncio.create_task(extra_sections.build_now(current[0], turned_on))
    await invalidate_home_cache()
    return {"sections": layout_entries(current[0])}


class ShareListeningIn(BaseModel):
    on: bool


@home_router.get("/share-listening")
def get_share_listening(current: tuple[str, str] = Depends(get_current_user)):
    """Sdílí profil, co poslouchá, s ostatními profily (sekce "Co poslouchá rodina")?"""
    from app.home.extra_sections import shares_listening

    with Session(engine) as session:
        return {"on": shares_listening(session, current[0])}


@home_router.put("/share-listening")
async def set_share_listening(body: ShareListeningIn, current: tuple[str, str] = Depends(get_current_user)):
    from app.home.extra_sections import share_key
    from app.home.service import invalidate_home_cache
    from app.models import HomeSnapshot
    from app.utils import utcnow

    with Session(engine) as session:
        row = session.get(HomeSnapshot, share_key(current[0])) or HomeSnapshot(key=share_key(current[0]))
        row.payload = {"on": body.on}
        row.generated_at = utcnow()
        session.add(row)
        if not body.on:
            # Vypnuté sdílení: stažení řady "Co poslouchá rodina" u ostatních
            # (playlist s mými posledními skladbami by jinak zůstal otevíratelný).
            from app.models import Playlist, PlaylistItem

            for pl in session.exec(select(Playlist).where(Playlist.source == f"home:rail:family_{current[0][:8]}")).all():
                for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == pl.id)).all():
                    session.delete(item)
                session.delete(pl)
        session.commit()
    await invalidate_home_cache()
    return {"on": body.on}


_refresh_running = False


@home_router.post("/refresh")
async def refresh_home(force: bool = False, current=Depends(get_current_user)):
    """Ruční přegenerování (jinak běží samo na pozadí, viz home_refresh_loop).
    Všechny generátory trvají ~3 min -- běží na pozadí, request hned vrátí.
    Vynucené (všechno znovu) jen admin; nikdy dvakrát souběžně."""
    global _refresh_running
    from app.auth import ADMIN_ID

    force = force and current[0] == ADMIN_ID
    if _refresh_running:
        return {"started": False, "running": True}

    async def run() -> None:
        global _refresh_running
        _refresh_running = True
        try:
            await run_generators(force=force)
        finally:
            _refresh_running = False

    asyncio.create_task(run())
    return {"started": True, "force": force}
