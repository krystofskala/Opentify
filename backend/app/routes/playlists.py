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

from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select

from app.auth import get_current_user
from app.catalog.availability import compute_availability, resolve_artist_name
from app.catalog.schemas import RecordingOut
from app.db import get_session
from app.home.generators import _covers_for
from app.models import GLOBAL_PLAYLIST_OWNER, Playlist, PlaylistItem, PlaylistKind, Recording
from app.recommendations.schemas import PlaylistDetailOut, PlaylistOut

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
        artist_name=resolve_artist_name(session, recording.artist_id),
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
    # Sdílené ze Spotify: jejich vlastní obal (uložený u nás), ne mozaika.
    if (playlist.source or "").startswith(("spotify-link:", "apple-link:")) and playlist.cover_urls:
        covers = list(playlist.cover_urls)
    else:
        covers = _covers_for(ids[:40]) or list(playlist.cover_urls or [])
    counts: Counter[str] = Counter()
    for recording_id in ids:
        recording = session.get(Recording, recording_id)
        if recording is not None and recording.artist_id:
            counts[recording.artist_id] += 1
    names = [name for artist_id, _ in counts.most_common(4) if (name := resolve_artist_name(session, artist_id))]
    return covers, names[:3]


def _playlist_detail(session: Session, playlist: Playlist) -> PlaylistDetailOut:
    items = _playlist_items(session, playlist.id)
    recordings = [r for item in items if (r := _to_recording_out(session, item.recording_id)) is not None]
    return PlaylistDetailOut(
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
    if playlist is None or playlist.owner_user_id not in (user_id, GLOBAL_PLAYLIST_OWNER):
        raise HTTPException(status_code=404, detail="playlist nenalezen")
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
        if p.source == "liked-songs":
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
    return results


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
    playlist = Playlist(owner_user_id=user_id, title=title, kind=PlaylistKind.USER)
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
    return _playlist_detail(session, playlist).model_dump(by_alias=True)


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
    for item in _playlist_items(session, playlist.id):
        session.delete(item)
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
    playlist = _owned_playlist_or_404(session, playlist_id, user_id)
    if session.get(Recording, body.recording_id) is None:
        raise HTTPException(status_code=404, detail="recording nenalezen v katalogu")

    existing = session.exec(
        select(PlaylistItem).where(
            PlaylistItem.playlist_id == playlist.id, PlaylistItem.recording_id == body.recording_id
        )
    ).first()
    if existing is None:
        position = len(_playlist_items(session, playlist.id))
        session.add(PlaylistItem(playlist_id=playlist.id, recording_id=body.recording_id, position=position))
        session.commit()
    return _playlist_detail(session, playlist).model_dump(by_alias=True)


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
    playlist = _owned_playlist_or_404(session, playlist_id, user_id)
    items = _playlist_items(session, playlist.id)
    current_ids = {item.recording_id for item in items}
    if set(body.recording_ids) != current_ids or len(body.recording_ids) != len(items):
        raise HTTPException(status_code=400, detail="nové pořadí neodpovídá aktuálním položkám playlistu")

    by_recording = {item.recording_id: item for item in items}
    for position, recording_id in enumerate(body.recording_ids):
        by_recording[recording_id].position = position
        session.add(by_recording[recording_id])
    session.commit()
    return _playlist_detail(session, playlist).model_dump(by_alias=True)


@playlists_router.delete("/{playlist_id}/items/{recording_id}")
def remove_item(
    playlist_id: str,
    recording_id: str,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    user_id, _device_id = current
    playlist = _owned_playlist_or_404(session, playlist_id, user_id)
    existing = session.exec(
        select(PlaylistItem).where(
            PlaylistItem.playlist_id == playlist.id, PlaylistItem.recording_id == recording_id
        )
    ).first()
    if existing is not None:
        session.delete(existing)
        session.commit()
    return _playlist_detail(session, playlist).model_dump(by_alias=True)
