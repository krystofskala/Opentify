"""REST routy pro vlastní uživatelské playlisty -- obecné CRUD nad
`Playlist`/`PlaylistItem` (`kind == USER`), co si uživatel sám pojmenuje a
naplní. Na rozdíl od `routes/library.py` (Liked Songs -- jeden pevný playlist
per uživatel, `source == "liked-songs"`) jde tu o libovolný počet playlistů,
co si uživatel sám zakládá/pojmenovává. Sdílí `PlaylistOut`/`PlaylistDetailOut`
s `app.recommendations.schemas`, aby generované (Daily Jams) i vlastní
playlisty vypadaly z pohledu klienta identicky (`PlaylistDetailModel` na
Dart straně je pro oba stejný typ)."""

from __future__ import annotations

from collections import Counter

from fastapi import APIRouter, Depends, HTTPException, UploadFile
from pydantic import BaseModel
from sqlmodel import Session, func, select

from app.auth import get_current_user
from app.catalog.availability import compute_availability, recording_artist_name, resolve_artist_name
from app.catalog.schemas import RecordingOut
from app.db import get_session
from app.home.generators import _covers_for
from app.models import GLOBAL_PLAYLIST_OWNER, Playlist, PlaylistItem, PlaylistKind, Recording
from app.recommendations.schemas import PlaylistDetailOut, PlaylistOut
from app.utils import utcnow

playlists_router = APIRouter(prefix="/playlists", tags=["playlists"])


class CreatePlaylistBody(BaseModel):
    title: str


class AddItemBody(BaseModel):
    recording_id: str


class ReorderItemsBody(BaseModel):
    """Kompletní nové pořadí `recording_id`s -- klient (drag-and-drop v
    `PlaylistDetailScreen`) posílá vždy celý seznam, ne jen přesunutou
    položku, stejný přístup jako `AudioPlayerController.reorderQueue` na
    frontendu (finální pořadí, ne relativní delta)."""

    recording_ids: list[str]


def _to_recording_out(session: Session, recording_id: str) -> RecordingOut | None:
    recording = session.get(Recording, recording_id)
    if recording is None:
        return None
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
        preview_url=recording.external_refs.get("previewUrl"),
    )


def _playlist_items(session: Session, playlist_id: str) -> list[PlaylistItem]:
    return session.exec(
        select(PlaylistItem).where(PlaylistItem.playlist_id == playlist_id).order_by(PlaylistItem.position)
    ).all()


def _preview(session: Session, playlist: Playlist, items: list[PlaylistItem]) -> tuple[list[str], list[str]]:
    """Náhled do seznamu playlistů (jako karty na Domů): mozaika z prvních
    různých obalů + nejčastější interpreti. Vlastní playlisty se mění, tak
    mozaika z aktuálních položek; uložená (kopie z Domů) jen jako záloha."""
    ids = [item.recording_id for item in items]
    # Vlastní nahraný obal (i z importu odkazem) a sdílené ze Spotify/Apple:
    # ten obal, ne mozaika -- dřív se vlastní obal ukázal jen v detailu.
    if playlist.cover_urls and (
        _has_custom_cover(playlist) or (playlist.source or "").startswith(("spotify-link:", "apple-link:"))
    ):
        covers = list(playlist.cover_urls)
    else:
        covers = _fast_covers(session, ids[:40]) or list(playlist.cover_urls or [])
    # Interpreti jedním seskupeným dotazem (dřív get na každou skladbu --
    # seznam playlistů měl 4 342 dotazů / 1,5 s).
    counts = session.exec(
        select(Recording.artist_id, func.count())
        .join(PlaylistItem, PlaylistItem.recording_id == Recording.id)
        .where(PlaylistItem.playlist_id == playlist.id, Recording.artist_id.is_not(None))  # type: ignore[union-attr]
        .group_by(Recording.artist_id)
        .order_by(func.count().desc())
        .limit(4)
    ).all()
    names = [name for artist_id, _n in counts if (name := resolve_artist_name(session, artist_id))]
    return covers, names[:3]


def _has_custom_cover(playlist: Playlist) -> bool:
    from app.catalog.embedded_art import URL_TEMPLATE

    own = URL_TEMPLATE.format(release_id=playlist.id)
    return any((url or "").startswith(own) for url in playlist.cover_urls or [])


def _fast_covers(session: Session, recording_ids: list[str]) -> list[str]:
    """Jako `_covers_for` (první 4 různé obaly, jinak fotka interpreta), ale
    jedním dotazem."""
    from app.models import Artist, Release

    if not recording_ids:
        return []
    rows = session.exec(
        select(Recording.id, Release.images, Artist.images)
        .outerjoin(Release, Release.id == Recording.release_id)
        .outerjoin(Artist, Artist.id == Recording.artist_id)
        .where(Recording.id.in_(recording_ids))  # type: ignore[attr-defined]
    ).all()
    by_id = {rid: (rel_imgs, art_imgs) for rid, rel_imgs, art_imgs in rows}
    covers: list[str] = []
    for rid in recording_ids:
        rel_imgs, art_imgs = by_id.get(rid, (None, None))
        cover = (rel_imgs or [None])[0] or (art_imgs or [None])[0]
        if cover and cover not in covers:
            covers.append(cover)
        if len(covers) == 4:
            break
    return covers


def _member_ids(session: Session, playlist_id: str) -> list[str]:
    from app.models import PlaylistMember

    return [
        m.user_id for m in session.exec(select(PlaylistMember).where(PlaylistMember.playlist_id == playlist_id)).all()
    ]


def _user_name(session: Session, user_id: str | None) -> str | None:
    from app.models import AppUser

    user = session.get(AppUser, user_id) if user_id else None
    return user.name if user else None


def _playlist_detail(session: Session, playlist: Playlist, user_id: str | None = None) -> PlaylistDetailOut:
    items = _playlist_items(session, playlist.id)
    from app.catalog.availability import prefetch_recordings

    _loaded = prefetch_recordings(session, [i.recording_id for i in items])  # noqa: F841 -- drží objekty v session
    recordings = [r for item in items if (r := _to_recording_out(session, item.recording_id)) is not None]
    members = _member_ids(session, playlist.id)
    collab = bool(members)
    role = None
    if collab and user_id:
        role = "owner" if playlist.owner_user_id == user_id else ("member" if user_id in members else None)
    names = {uid: _user_name(session, uid) for uid in {playlist.owner_user_id, *members}} if collab else {}
    return PlaylistDetailOut(
        role=role,
        members=[n for uid in [playlist.owner_user_id, *members] if (n := names.get(uid))],
        added_by={
            item.recording_id: names.get(item.added_by) or (_user_name(session, item.added_by) or "")
            for item in items
            if collab and item.added_by
        },
        id=playlist.id,
        title=playlist.title,
        kind=playlist.kind,
        source=playlist.source,
        generated_at=playlist.generated_at,
        item_count=len(recordings),
        items=recordings,
        description=playlist.description,
        cover_urls=playlist.cover_urls or _covers_for([item.recording_id for item in items[:40]]),
    )


def _readable_playlist_or_404(session: Session, playlist_id: str, user_id: str) -> Playlist:
    """Čtení: vlastní playlisty + globální snapshoty z Domů (žebříčky,
    žánry, výběry). Úpravy dál jen přes `_owned_playlist_or_404`."""
    playlist = session.get(Playlist, playlist_id)
    if playlist is None or (
        playlist.owner_user_id not in (user_id, GLOBAL_PLAYLIST_OWNER) and user_id not in _member_ids(session, playlist_id)
    ):
        raise HTTPException(status_code=404, detail="playlist nenalezen")
    return playlist


def _drop_invites(session: Session, playlist_id: str) -> None:
    """Pozvánky do společného playlistu (HomeSnapshot playlist-invite:*)."""
    from app.models import HomeSnapshot

    for snap in session.exec(select(HomeSnapshot).where(HomeSnapshot.key.startswith("playlist-invite:"))).all():  # type: ignore[union-attr]
        if (snap.payload or {}).get("playlistId") == playlist_id:
            session.delete(snap)


def _drop_pins(session: Session, playlist_id: str, user_ids: list[str] | None = None) -> None:
    from app.models import PinnedPlaylist

    q = select(PinnedPlaylist).where(PinnedPlaylist.playlist_id == playlist_id)
    if user_ids is not None:
        q = q.where(PinnedPlaylist.user_id.in_(user_ids))  # type: ignore[attr-defined]
    for row in session.exec(q).all():
        session.delete(row)


LIKED_SONGS = "liked-songs"


def _require_user_kind(playlist: Playlist) -> None:
    """Generované playlisty (mixy, Denní mix, rádia, žebříčky) přegeneruje
    server -- ruční úpravy by se ztratily a klient je stejně ukazuje jen
    pro čtení (`isReadOnly`). Do knihovny se jen připínají (`/pin`)."""
    if playlist.kind != PlaylistKind.USER:
        raise HTTPException(status_code=403, detail="Tenhle playlist se generuje automaticky, upravit ho nejde.")


def _require_not_liked(playlist: Playlist) -> None:
    """Oblíbené (`source == liked-songs`) jsou pevný playlist profilu -- lajky
    jdou přes `/library/liked-songs`; smazání by vzalo všechny lajky."""
    if playlist.source == LIKED_SONGS:
        raise HTTPException(status_code=403, detail="Oblíbené skladby nejde přejmenovat, smazat ani sdílet.")


def _editable_playlist_or_404(session: Session, playlist_id: str, user_id: str) -> Playlist:
    """Skladby mění vlastník i členové společného playlistu."""
    playlist = session.get(Playlist, playlist_id)
    if playlist is None or (playlist.owner_user_id != user_id and user_id not in _member_ids(session, playlist_id)):
        raise HTTPException(status_code=404, detail="playlist nenalezen")
    _require_user_kind(playlist)
    return playlist


def _owned_playlist_or_404(session: Session, playlist_id: str, user_id: str) -> Playlist:
    playlist = session.get(Playlist, playlist_id)
    if playlist is None or playlist.owner_user_id != user_id:
        raise HTTPException(status_code=404, detail="playlist nenalezen")
    return playlist


@playlists_router.get("")
def list_playlists(
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Jen VLASTNÍ playlisty (`kind == USER` A ZÁROVEŇ ne Liked Songs) --
    generované (Daily Jams) mají svoje `/recommendations/*` endpointy, Liked
    Songs `/library/liked-songs`. Bez vyloučení `source == liked-songs` by se
    sem "Liked Songs" míchalo dvakrát (i tady, i ve vlastním endpointu)."""
    user_id, _device_id = current
    playlists = session.exec(
        select(Playlist)
        .where(Playlist.owner_user_id == user_id, Playlist.kind == PlaylistKind.USER)
        .order_by(Playlist.updated_at.desc())
    ).all()
    results = []
    for p in playlists:
        if p.source == LIKED_SONGS:
            continue
        items = _playlist_items(session, p.id)
        covers, artist_names = _preview(session, p, items)
        out = PlaylistOut(
            id=p.id,
            title=p.title,
            kind=p.kind,
            source=p.source,
            generated_at=p.generated_at,
            item_count=len(items),
        ).model_dump(by_alias=True)
        results.append({
            **out,
            "coverUrls": covers,
            "artistNames": artist_names,
            "description": p.description,
            "updatedAt": p.updated_at.isoformat() if p.updated_at else None,
        })
    # Společné playlisty, kde je profil členem.
    from app.models import PinnedPlaylist, PlaylistMember

    owned_ids = {r["id"] for r in results}
    for m in session.exec(select(PlaylistMember).where(PlaylistMember.user_id == user_id)).all():
        p = session.get(Playlist, m.playlist_id)
        if p is None or p.id in owned_ids:
            continue
        items = _playlist_items(session, p.id)
        covers, artist_names = _preview(session, p, items)
        out = PlaylistOut(
            id=p.id, title=p.title, kind=p.kind, source=p.source, generated_at=p.generated_at, item_count=len(items)
        ).model_dump(by_alias=True)
        results.append({
            **out,
            "coverUrls": covers,
            "artistNames": artist_names,
            "description": p.description,
            "updatedAt": p.updated_at.isoformat() if p.updated_at else None,
            "collab": True,
            # Jsem jen člen (ne vlastník) -- "Opustit", ne "Smazat", i když
            # vlastník mezitím zmizel a jméno není.
            "member": True,
            "ownerName": _user_name(session, p.owner_user_id) or "smazaný profil",
        })
    # Vlastní, které jsou sdílené (štítek "Společný").
    for r in results:
        if r["id"] in owned_ids and _member_ids(session, r["id"]):
            r["collab"] = True

    listed = {r["id"] for r in results}
    for pin in session.exec(select(PinnedPlaylist).where(PinnedPlaylist.user_id == user_id)).all():
        p = session.get(Playlist, pin.playlist_id)
        if p is None or p.id in listed:
            continue
        if p.owner_user_id not in (user_id, GLOBAL_PLAYLIST_OWNER) and user_id not in _member_ids(session, p.id):
            continue  # už nemá přístup (zrušené sdílení)
        listed.add(p.id)
        items = _playlist_items(session, p.id)
        covers, artist_names = _preview(session, p, items)
        out = PlaylistOut(
            id=p.id, title=p.title, kind=p.kind, source=p.source, generated_at=p.generated_at, item_count=len(items)
        ).model_dump(by_alias=True)
        results.append({
            **out,
            "coverUrls": covers,
            "artistNames": artist_names,
            "description": p.description,
            "updatedAt": pin.added_at.isoformat() if pin.added_at else None,
            "pinned": True,
        })
    return results


class UpdatePlaylistBody(BaseModel):
    title: str | None = None
    description: str | None = None


@playlists_router.patch("/{playlist_id}")
def update_playlist(
    playlist_id: str,
    body: UpdatePlaylistBody,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Název a krátký popis vlastního playlistu."""
    user_id, _device_id = current
    playlist = _owned_playlist_or_404(session, playlist_id, user_id)
    _require_user_kind(playlist)
    if body.title is not None and body.title.strip() != playlist.title:
        _require_not_liked(playlist)
    if body.title is not None:
        title = body.title.strip()
        if not title:
            raise HTTPException(status_code=400, detail="název playlistu nesmí být prázdný")
        playlist.title = title[:200]
    if body.description is not None:
        playlist.description = body.description.strip()[:500] or None
    playlist.updated_at = utcnow()
    session.add(playlist)
    session.commit()
    session.refresh(playlist)
    return _playlist_detail(session, playlist).model_dump(by_alias=True)


@playlists_router.post("/{playlist_id}/cover")
async def upload_playlist_cover(
    playlist_id: str,
    file: UploadFile,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Vlastní obal playlistu (místo mozaiky z obalů skladeb)."""
    import asyncio

    from app.catalog.embedded_art import URL_TEMPLATE, save_custom_cover
    from app.uploads import read_limited

    user_id, _device_id = current
    playlist = _owned_playlist_or_404(session, playlist_id, user_id)
    _require_user_kind(playlist)
    raw = await read_limited(file, 15 * 1024 * 1024, "Obrázek")
    if not await asyncio.to_thread(save_custom_cover, raw, playlist.id):
        raise HTTPException(status_code=400, detail="Tohle není obrázek (nebo je moc malý).")
    # Verze v URL -- obrázek se servíruje jako immutable na týden, nový by
    # se jinak neukázal.
    playlist.cover_urls = [URL_TEMPLATE.format(release_id=playlist.id) + f"?v={int(utcnow().timestamp())}"]
    playlist.updated_at = utcnow()
    session.add(playlist)
    session.commit()
    session.refresh(playlist)
    return _playlist_detail(session, playlist).model_dump(by_alias=True)


@playlists_router.delete("/{playlist_id}/cover")
def remove_playlist_cover(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Zpátky na mozaiku z obalů skladeb."""
    user_id, _device_id = current
    playlist = _owned_playlist_or_404(session, playlist_id, user_id)
    _require_user_kind(playlist)
    playlist.cover_urls = []
    playlist.updated_at = utcnow()
    session.add(playlist)
    session.commit()
    session.refresh(playlist)
    return _playlist_detail(session, playlist).model_dump(by_alias=True)


@playlists_router.post("/{playlist_id}/pin")
def pin_playlist(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """"Přidat a nechat aktualizovat": mix zůstane živý, jen je v Knihovně."""
    from app.models import PinnedPlaylist

    user_id, _device_id = current
    _readable_playlist_or_404(session, playlist_id, user_id)
    exists = session.exec(
        select(PinnedPlaylist).where(PinnedPlaylist.user_id == user_id, PinnedPlaylist.playlist_id == playlist_id)
    ).first()
    if exists is None:
        session.add(PinnedPlaylist(user_id=user_id, playlist_id=playlist_id))
        session.commit()
    return {"playlistId": playlist_id, "pinned": True}


@playlists_router.delete("/{playlist_id}/pin")
def unpin_playlist(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    from app.models import PinnedPlaylist

    user_id, _device_id = current
    for row in session.exec(
        select(PinnedPlaylist).where(PinnedPlaylist.user_id == user_id, PinnedPlaylist.playlist_id == playlist_id)
    ).all():
        session.delete(row)
    session.commit()
    return {"playlistId": playlist_id, "pinned": False}


@playlists_router.post("")
def create_playlist(
    body: CreatePlaylistBody,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    title = body.title.strip()
    if not title:
        raise HTTPException(status_code=400, detail="název playlistu nesmí být prázdný")
    # Stejný strop jako při přejmenování (simulace: šlo založit 5000 znaků).
    playlist = Playlist(owner_user_id=user_id, title=title[:200], kind=PlaylistKind.USER)
    session.add(playlist)
    session.commit()
    session.refresh(playlist)
    return _playlist_detail(session, playlist).model_dump(by_alias=True)


@playlists_router.get("/{playlist_id}")
def get_playlist(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    playlist = _readable_playlist_or_404(session, playlist_id, user_id)
    return _playlist_detail(session, playlist, user_id).model_dump(by_alias=True)


@playlists_router.post("/{playlist_id}/copy")
def copy_playlist(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """"Přidat do knihovny" -- žebříček/mix z Domů jako vlastní playlist
    (zmrazená kopie; původní snapshot se dál přegenerovává)."""
    user_id, _device_id = current
    source = _readable_playlist_or_404(session, playlist_id, user_id)
    copy = Playlist(owner_user_id=user_id, title=source.title, kind=PlaylistKind.USER, cover_urls=source.cover_urls or [])
    session.add(copy)
    session.flush()
    for position, item in enumerate(_playlist_items(session, source.id)):
        session.add(PlaylistItem(playlist_id=copy.id, recording_id=item.recording_id, position=position))
    session.commit()
    session.refresh(copy)
    return _playlist_detail(session, copy).model_dump(by_alias=True)


@playlists_router.delete("/{playlist_id}")
def delete_playlist(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    playlist = _owned_playlist_or_404(session, playlist_id, user_id)
    _require_user_kind(playlist)
    _require_not_liked(playlist)
    from app.models import PinnedPlaylist, PlaylistMember

    for item in _playlist_items(session, playlist.id):
        session.delete(item)
    # Členové společného playlistu, připnutí a pozvánky -- ať nezůstanou osiřelé.
    for model in (PlaylistMember, PinnedPlaylist):
        for row in session.exec(select(model).where(model.playlist_id == playlist.id)).all():
            session.delete(row)
    _drop_invites(session, playlist.id)
    session.delete(playlist)
    session.commit()
    return {"deleted": True}


@playlists_router.post("/{playlist_id}/items")
def add_item(
    playlist_id: str,
    body: AddItemBody,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    playlist = _editable_playlist_or_404(session, playlist_id, user_id)
    if session.get(Recording, body.recording_id) is None:
        raise HTTPException(status_code=404, detail="recording nenalezen v katalogu")

    # Souběžná přidání do téhož (společného) playlistu dřív dostala stejnou
    # pozici -- pořadí pak bylo náhodné. Čtení maxima + zápis pod zámkem.
    from app.locks import keyed

    with keyed(f"playlist-items:{playlist.id}"):
        session.expire_all()
        existing = session.exec(
            select(PlaylistItem).where(
                PlaylistItem.playlist_id == playlist.id, PlaylistItem.recording_id == body.recording_id
            )
        ).first()
        if existing is None:
            # Za poslední (po odebrání můžou v pozicích být díry -- len() by dal duplicitu).
            position = max((i.position for i in _playlist_items(session, playlist.id)), default=-1) + 1
            session.add(
                PlaylistItem(playlist_id=playlist.id, recording_id=body.recording_id, position=position, added_by=user_id)
            )
            playlist.updated_at = utcnow()
            session.add(playlist)
            session.commit()
    return _playlist_detail(session, playlist, user_id).model_dump(by_alias=True)


@playlists_router.patch("/{playlist_id}/items/reorder")
def reorder_items(
    playlist_id: str,
    body: ReorderItemsBody,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Přepíše `PlaylistItem.position` podle nového pořadí z klienta.
    Vyžaduje přesnou permutaci současných položek -- žádné přidávání/mazání
    tudy (na to `add_item`/`remove_item`), ať omylem neztratíme položku kvůli
    zastaralému seznamu na klientovi (např. mezitím smazané jinde)."""
    user_id, _device_id = current
    playlist = _editable_playlist_or_404(session, playlist_id, user_id)
    items = _playlist_items(session, playlist.id)
    current_ids = {item.recording_id for item in items}
    if set(body.recording_ids) != current_ids or len(body.recording_ids) != len(items):
        raise HTTPException(status_code=400, detail="nové pořadí neodpovídá aktuálním položkám playlistu")

    by_recording = {item.recording_id: item for item in items}
    for position, recording_id in enumerate(body.recording_ids):
        by_recording[recording_id].position = position
        session.add(by_recording[recording_id])
    # Řazení "Upraveno" v Knihovně a obnova otevřeného detailu jinde.
    playlist.updated_at = utcnow()
    session.add(playlist)
    session.commit()
    return _playlist_detail(session, playlist, user_id).model_dump(by_alias=True)


@playlists_router.delete("/{playlist_id}/items/{recording_id}")
def remove_item(
    playlist_id: str,
    recording_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    playlist = _editable_playlist_or_404(session, playlist_id, user_id)
    existing = session.exec(
        select(PlaylistItem).where(
            PlaylistItem.playlist_id == playlist.id, PlaylistItem.recording_id == recording_id
        )
    ).first()
    if existing is not None:
        session.delete(existing)
        playlist.updated_at = utcnow()
        session.add(playlist)
        session.commit()
    return _playlist_detail(session, playlist, user_id).model_dump(by_alias=True)


# --- Společné playlisty ------------------------------------------------------
# Sdílí se odkazem s kódem (ne výběrem ze seznamu profilů -- kamarádi nemají
# vidět ostatní profily). Kdo odkaz otevře, stane se členem.


@playlists_router.post("/{playlist_id}/invite")
def invite_to_playlist(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    import secrets

    user_id, _device_id = current
    playlist = _owned_playlist_or_404(session, playlist_id, user_id)
    _require_user_kind(playlist)
    _require_not_liked(playlist)
    code = secrets.token_urlsafe(8)
    from app.models import HomeSnapshot

    session.add(HomeSnapshot(key=f"playlist-invite:{code}", payload={"playlistId": playlist.id}))
    session.commit()
    return {"code": code, "path": f"/playlist-join/{code}"}


@playlists_router.post("/join/{code}")
def join_playlist(
    code: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    from datetime import timedelta

    from app.models import HomeSnapshot, PlaylistMember

    user_id, _device_id = current
    invite = session.get(HomeSnapshot, f"playlist-invite:{code}")
    if invite is None:
        raise HTTPException(status_code=404, detail="Pozvánka neplatí.")
    created = invite.generated_at if invite.generated_at.tzinfo else invite.generated_at.replace(tzinfo=utcnow().tzinfo)
    if utcnow() - created > timedelta(days=30):
        raise HTTPException(status_code=410, detail="Pozvánka už vypršela, požádej o novou.")
    playlist = session.get(Playlist, (invite.payload or {}).get("playlistId"))
    if playlist is None:
        raise HTTPException(status_code=404, detail="Playlist už neexistuje.")
    if playlist.owner_user_id != user_id and user_id not in _member_ids(session, playlist.id):
        session.add(PlaylistMember(playlist_id=playlist.id, user_id=user_id))
        session.commit()
    return {"playlistId": playlist.id, "title": playlist.title}


@playlists_router.delete("/{playlist_id}/members/me")
def leave_playlist(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Člen opustí společný playlist (vlastník ho jen smaže)."""
    from app.models import PlaylistMember

    user_id, _device_id = current
    for row in session.exec(
        select(PlaylistMember).where(PlaylistMember.playlist_id == playlist_id, PlaylistMember.user_id == user_id)
    ).all():
        session.delete(row)
    _drop_pins(session, playlist_id, [user_id])
    session.commit()
    return {"left": True}


@playlists_router.delete("/{playlist_id}/members")
def stop_sharing(
    playlist_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    """Vlastník zruší sdílení -- playlist zůstane jen jemu."""
    from app.models import PlaylistMember

    user_id, _device_id = current
    _owned_playlist_or_404(session, playlist_id, user_id)
    members = []
    for row in session.exec(select(PlaylistMember).where(PlaylistMember.playlist_id == playlist_id)).all():
        members.append(row.user_id)
        session.delete(row)
    _drop_pins(session, playlist_id, members)
    _drop_invites(session, playlist_id)  # starým odkazem se už nikdo nepřipojí
    session.commit()
    return {"shared": False}
