"""Nelíbí se mi (zlomené srdce): skladby, které uživatel nechce slyšet.

Dlouhé podržení srdíčka v appce přepne na zlomené srdce, další dlouhé
podržení ho zruší. Zlomené srdce:
  - odebere skladbu z Oblíbených,
  - vyřadí ji ze všech generovaných výběrů (mixy na Domů, rádia, denní
    doporučení) -- `without_disliked` volají ukládací funkce snapshotů,
  - pošle na ListenBrainz zpětnou vazbu "hate" (score -1; zrušení = 0),
    stejně jako tam jdou poslechy (token profilu, viz `app.listens.token_for`), jen pro skladby
    s MusicBrainz ID. Best effort -- výpadek LB nic nerozbije.
"""

from __future__ import annotations

import asyncio
import logging
import os

import httpx
from sqlmodel import Session, select

from app.db import engine
from app.models import GLOBAL_PLAYLIST_OWNER, Playlist, PlaylistItem, PlaylistKind, Recording, RecordingDislike

logger = logging.getLogger(__name__)
LB_API = os.environ.get("LISTENBRAINZ_SUBMIT_BASE_URL", "https://api.listenbrainz.org")


def disliked_ids(session: Session, user_id: str | None) -> set[str]:
    """`None`/globální vlastník = všechny zlomená srdce (appka je pro jednoho
    uživatele, globální žebříčky ho taky nemají strašit)."""
    query = select(RecordingDislike.recording_id)
    if user_id and user_id != GLOBAL_PLAYLIST_OWNER:
        query = query.where(RecordingDislike.user_id == user_id)
    return set(session.exec(query).all())


def without_disliked(user_id: str | None, recording_ids: list[str]) -> list[str]:
    with Session(engine) as session:
        bad = disliked_ids(session, user_id)
    return [rid for rid in recording_ids if rid not in bad] if bad else recording_ids


async def send_feedback(recording_id: str, score: int, user_id: str) -> None:
    from app.listens import token_for

    token = token_for(user_id)  # jen token TOHO profilu, nikdy cizí
    if not token:
        return
    with Session(engine) as session:
        recording = session.get(Recording, recording_id)
        mbid = recording.mbid if recording else None
    if not mbid:
        return
    try:
        async with httpx.AsyncClient(timeout=15) as client:
            response = await client.post(
                f"{LB_API}/1/feedback/recording-feedback",
                json={"recording_mbid": mbid, "score": score},
                headers={"Authorization": f"Token {token}"},
            )
            if response.status_code >= 400:
                logger.warning("LB feedback %s pro %s: HTTP %s", score, mbid, response.status_code)
    except httpx.HTTPError as exc:
        logger.warning("LB feedback nešel: %s", exc)


def purge_from_snapshots(session: Session, recording_id: str, user_id: str) -> int:
    """Zlomené srdce platí hned, ne až při dalším přegenerování: skladba
    zmizí z už uložených mixů a rádií TOHOTO profilu (ne z mixů ostatních
    ani ze společných žebříčků). Vlastní playlisty a historie (roční top
    skladby, dekáda) zůstávají, jak jsou."""
    rows = session.exec(
        select(PlaylistItem)
        .join(Playlist, Playlist.id == PlaylistItem.playlist_id)
        .where(
            PlaylistItem.recording_id == recording_id,
            Playlist.owner_user_id == user_id,
            Playlist.kind != PlaylistKind.USER,
            ~Playlist.source.startswith("personal:year:"),
            ~Playlist.source.startswith("personal:decade:"),
        )
    ).all()
    for row in rows:
        session.delete(row)
    return len(rows)


# Poslední odeslání pro každou skladbu: rychlé zlomit/spravit musí na LB
# dorazit ve stejném pořadí, jinak by tam mohlo zůstat "hate".
_last_feedback: dict[str, asyncio.Task] = {}


async def _send_after(previous: asyncio.Task | None, recording_id: str, score: int, user_id: str) -> None:
    if previous is not None:
        try:
            await previous
        except Exception:  # noqa: BLE001 -- best effort
            pass
    await send_feedback(recording_id, score, user_id)


def send_feedback_later(recording_id: str, score: int, user_id: str) -> None:
    """Na ListenBrainz profilu `user_id` (jeho token; bez tokenu nic)."""
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return
    key = f"{user_id}:{recording_id}"
    previous = _last_feedback.get(key)
    task = loop.create_task(_send_after(previous, recording_id, score, user_id))
    _last_feedback[key] = task
    task.add_done_callback(lambda t: _last_feedback.get(key) is t and _last_feedback.pop(key, None))
