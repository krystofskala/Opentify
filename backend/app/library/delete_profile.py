"""Smazání profilu se všemi jeho daty (žádost člověka, admin to provede).

Smaže se: poslechy, knihovna, oblíbené a neoblíbené, playlisty profilu
(i s vlastními obaly), členství ve sdílených playlistech, Poslechni později,
blendy, zařízení a pozvánky, osobní snímky Domů a klíče v Redisu, tokeny
ListenBrainz/Last.fm (jsou na profilu). Skladby, které profil přidal do
cizích sdílených playlistů, v nich zůstanou, jen bez jména přidávajícího.
Stažená hudba zůstává -- je společná pro celý server."""
from __future__ import annotations

import logging

from sqlalchemy import delete, or_, update
from sqlmodel import Session, select

from app.auth import ADMIN_ID
from app.db import engine
from app.models import (
    AppUser,
    ArtistDislike,
    ArtistFeedback,
    DownloadRequest,
    RecBatchItem,
    PendingImportPlay,
    PodcastListenHistory,
    PodcastProgress,
    PodcastSubscription,
    SpokenBook,
    SpokenFavorite,
    SpokenProgress,
    AuthToken,
    Blend,
    CollectionProgress,
    FavoriteArtist,
    HeardFully,
    HomeImpression,
    HomeSnapshot,
    InviteCode,
    LibraryEntry,
    Listen,
    ListenLater,
    PairCode,
    PinnedPlaylist,
    PlayEvent,
    Playlist,
    PlaylistItem,
    PlaylistMember,
    ProvisioningJob,
    RecordingDislike,
    SkipStreak,
)

logger = logging.getLogger(__name__)

# Každá tabulka se sloupcem `user_id` (hlídá test_delete_profile_covers_all).
_PER_USER = [Listen, PlayEvent, SkipStreak, RecordingDislike, HeardFully, AuthToken, InviteCode, PairCode,
             LibraryEntry, PlaylistMember, PinnedPlaylist, ArtistDislike, FavoriteArtist, CollectionProgress,
             ListenLater, HomeImpression, ArtistFeedback, PendingImportPlay, SpokenProgress, SpokenFavorite, PodcastSubscription, PodcastProgress, PodcastListenHistory,
             DownloadRequest, RecBatchItem]


def delete_profile(user_id: str) -> dict[str, int]:
    if user_id == ADMIN_ID:
        raise ValueError("Admin profil smazat nejde.")
    counts: dict[str, int] = {}
    with Session(engine) as session:
        if session.get(AppUser, user_id) is None:
            raise LookupError("Profil neexistuje.")
        # Kromě vlastních i blendy u partnera (`blend:<id>:*`) a řada "Co
        # poslouchá rodina" s mými skladbami u ostatních -- jinak by po
        # smazání zůstaly otevíratelné.
        blend_ids = list(session.exec(
            select(Blend.id).where(or_(Blend.user_a == user_id, Blend.user_b == user_id, Blend.created_by == user_id))
        ).all())
        playlist_ids = list(session.exec(select(Playlist.id).where(or_(
            Playlist.owner_user_id == user_id,
            Playlist.source == f"home:rail:family_{user_id[:8]}",
            *(Playlist.source.like(f"blend:{bid}:%") for bid in blend_ids),  # type: ignore[union-attr]
        ))).all())
        if playlist_ids:
            for model in (PlaylistItem, PlaylistMember, PinnedPlaylist):
                session.exec(delete(model).where(model.playlist_id.in_(playlist_ids)))  # type: ignore[attr-defined]
            counts["playlists"] = session.exec(delete(Playlist).where(Playlist.id.in_(playlist_ids))).rowcount  # type: ignore[union-attr]
        # Příspěvky do cizích sdílených playlistů zůstanou, bez jména.
        session.exec(update(PlaylistItem).where(PlaylistItem.added_by == user_id).values(added_by=None))
        for model in _PER_USER:
            n = session.exec(delete(model).where(model.user_id == user_id)).rowcount  # type: ignore[attr-defined]
            if n:
                counts[model.__tablename__] = n
        counts["blends"] = session.exec(
            delete(Blend).where(or_(Blend.user_a == user_id, Blend.user_b == user_id, Blend.created_by == user_id))
        ).rowcount
        # Joby stahování jsou společné -- jen bez vazby na profil.
        session.exec(update(SpokenBook).where(SpokenBook.requested_by_user_id == user_id).values(requested_by_user_id=ADMIN_ID))
        session.exec(update(ProvisioningJob).where(ProvisioningJob.requested_by_user_id == user_id)
                     .values(requested_by_user_id=ADMIN_ID))
        counts["snapshots"] = session.exec(delete(HomeSnapshot).where(HomeSnapshot.key.contains(user_id))).rowcount  # type: ignore[attr-defined]
        session.exec(delete(AppUser).where(AppUser.id == user_id))
        session.commit()
    _delete_covers(playlist_ids)
    counts["redis"] = _delete_redis(user_id)
    logger.info("smazán profil %s: %s", user_id, counts)
    return counts


def _delete_covers(playlist_ids: list[str]) -> None:
    from app.catalog.embedded_art import artwork_path, artwork_png_path

    for pid in playlist_ids:
        try:
            artwork_path(pid).unlink(missing_ok=True)
            artwork_png_path(pid).unlink(missing_ok=True)
        except OSError:
            logger.warning("obal playlistu %s nejde smazat", pid)


def _delete_redis(user_id: str) -> int:
    import redis

    from app.redis_bus import REDIS_URL

    r = redis.Redis.from_url(REDIS_URL)
    keys = list(r.scan_iter(match=f"*{user_id}*", count=1000))
    if keys:
        r.delete(*keys)
    return len(keys)
