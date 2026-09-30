"""Nelíbí se mi (zlomené srdce): skladby, které uživatel nechce slyšet.

Dlouhé podržení srdíčka v appce přepne na zlomené srdce, další dlouhé
podržení ho zruší. Zlomené srdce:
  - odebere skladbu z Oblíbených,
  - vyřadí ji ze všech generovaných výběrů (mixy na Domů, rádia, denní
    doporučení) -- `without_disliked` volají ukládací funkce snapshotů,
  - pošle na ListenBrainz zpětnou vazbu "hate" (score -1; zrušení = 0),
    stejně jako tam jdou poslechy (`LISTENBRAINZ_TOKEN`), jen pro skladby
    s MusicBrainz ID. Best effort -- výpadek LB nic nerozbije.
"""

from __future__ import annotations

import asyncio
import logging
import os

import httpx
from sqlmodel import Session, select

from app.db import engine
from app.models import GLOBAL_PLAYLIST_OWNER, Recording, RecordingDislike

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


async def send_feedback(recording_id: str, score: int) -> None:
    token = os.environ.get("LISTENBRAINZ_TOKEN")
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


def send_feedback_later(recording_id: str, score: int) -> None:
    try:
        asyncio.get_running_loop().create_task(send_feedback(recording_id, score))
    except RuntimeError:
        pass
