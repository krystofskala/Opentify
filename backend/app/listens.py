"""Poslechy (scrobbling): lokální historie + odeslání do ListenBrainz.

Klient hlásí poslech, jakmile skladba hrála aspoň polovinu délky nebo
4 minuty (standardní pravidlo scrobblování). Poslech se nejdřív uloží do
tabulky `Listen` (zdroj pro osobní mixy), odeslání do ListenBrainz běží
zvlášť na pozadí: neodeslané poslechy (`lb_submitted_at is None`) se
zkoušejí znovu, takže výpadek sítě nebo ListenBrainz nic neztratí.
Token se nikdy neloguje.
"""

from __future__ import annotations

import asyncio
import logging
import os
from datetime import datetime, timezone
from typing import Any

import httpx
from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, Listen, Recording, Release
from app.utils import utcnow

logger = logging.getLogger(__name__)

LB_API = os.environ.get("LISTENBRAINZ_SUBMIT_BASE_URL", "https://api.listenbrainz.org")
_MAX_ATTEMPTS = 10
_BATCH = 100
_http = httpx.AsyncClient(timeout=15.0)
_wakeup = asyncio.Event()


def _token() -> str | None:
    return os.environ.get("LISTENBRAINZ_TOKEN") or None


def record_listen(
    user_id: str,
    recording_id: str,
    *,
    played_at: datetime | None = None,
    duration_played_ms: int | None = None,
    source: str | None = None,
) -> str | None:
    """Sync -- vrátí id poslechu, `None` když nahrávka neexistuje."""
    with Session(engine) as session:
        if session.get(Recording, recording_id) is None:
            return None
        listen = Listen(
            user_id=user_id,
            recording_id=recording_id,
            played_at=played_at or utcnow(),
            duration_played_ms=duration_played_ms,
            source=source,
        )
        session.add(listen)
        session.commit()
        listen_id = listen.id
    _wakeup.set()
    return listen_id


def _track_metadata(session: Session, recording: Recording) -> dict[str, Any] | None:
    artist = session.get(Artist, recording.artist_id) if recording.artist_id else None
    if artist is None or not recording.title:
        return None
    release = session.get(Release, recording.release_id) if recording.release_id else None
    info: dict[str, Any] = {
        "submission_client": "Opentify",
        "submission_client_version": "0.1",
        "media_player": "Opentify",
    }
    if recording.mbid:
        info["recording_mbid"] = recording.mbid
    if recording.isrc:
        info["isrc"] = recording.isrc
    if recording.duration_ms:
        info["duration_ms"] = recording.duration_ms
    if artist.mbid:
        info["artist_mbids"] = [artist.mbid]
    if release is not None and release.mbid:
        # Release.mbid je MB release-GROUP id (viz catalog/upsert.py).
        info["release_group_mbid"] = release.mbid
    meta: dict[str, Any] = {"artist_name": artist.name, "track_name": recording.title, "additional_info": info}
    if release is not None and release.title:
        meta["release_name"] = release.title
    return meta


def _epoch(value: datetime) -> int:
    return int((value if value.tzinfo else value.replace(tzinfo=timezone.utc)).timestamp())


async def _post(payload: dict[str, Any]) -> httpx.Response:
    return await _http.post(
        f"{LB_API}/1/submit-listens",
        json=payload,
        headers={"Authorization": f"Token {_token()}"},
    )


async def submit_playing_now(recording_id: str) -> None:
    """"Právě hraje" -- best-effort, nic se neukládá ani neopakuje."""
    if not _token():
        return
    with Session(engine) as session:
        recording = session.get(Recording, recording_id)
        meta = _track_metadata(session, recording) if recording else None
    if meta is None:
        return
    try:
        await _post({"listen_type": "playing_now", "payload": [{"track_metadata": meta}]})
    except httpx.HTTPError:
        pass


async def submit_pending() -> int:
    """Odešle neodeslané poslechy (nejstarší první). Vrátí počet odeslaných."""
    if not _token():
        return 0
    with Session(engine) as session:
        pending = session.exec(
            select(Listen)
            .where(Listen.lb_submitted_at.is_(None), Listen.lb_attempts < _MAX_ATTEMPTS)  # type: ignore[union-attr]
            .order_by(Listen.played_at)
            .limit(_BATCH)
        ).all()
        entries: list[tuple[str, dict[str, Any]]] = []
        for listen in pending:
            recording = session.get(Recording, listen.recording_id)
            meta = _track_metadata(session, recording) if recording else None
            if meta is None:
                listen.lb_attempts = _MAX_ATTEMPTS  # nejde odeslat (chybí interpret/název) -- nezkoušet znovu
                listen.lb_error = "chybí metadata"
                session.add(listen)
                continue
            entries.append((listen.id, {"listened_at": _epoch(listen.played_at), "track_metadata": meta}))
        session.commit()
    if not entries:
        return 0

    payload = {"listen_type": "single" if len(entries) == 1 else "import", "payload": [e for _, e in entries]}
    try:
        resp = await _post(payload)
        ok, error = resp.status_code == 200, None if resp.status_code == 200 else f"HTTP {resp.status_code}: {resp.text[:200]}"
    except httpx.HTTPError as exc:
        ok, error = False, f"síť: {type(exc).__name__}"

    ids = [listen_id for listen_id, _ in entries]
    with Session(engine) as session:
        for listen_id in ids:
            listen = session.get(Listen, listen_id)
            if listen is None:
                continue
            if ok:
                listen.lb_submitted_at = utcnow()
                listen.lb_error = None
            else:
                listen.lb_attempts += 1
                listen.lb_error = error
            session.add(listen)
        session.commit()
    if not ok:
        logger.warning("ListenBrainz: odeslání %d poslechů selhalo (%s), zkusím znovu", len(ids), error)
        return 0
    return len(ids)


async def lb_submit_loop(interval_s: float = 60.0) -> None:
    """Na pozadí v API: odesílá hned po novém poslechu (probuzení z
    `record_listen`) a jinak jednou za minutu zkouší, co dřív selhalo."""
    await asyncio.sleep(10)
    while True:
        try:
            while await submit_pending() >= _BATCH:
                await asyncio.sleep(1)
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - smyčka nesmí umřít
            logger.exception("ListenBrainz: odesílací smyčka selhala")
        _wakeup.clear()
        try:
            await asyncio.wait_for(_wakeup.wait(), timeout=interval_s)
        except asyncio.TimeoutError:
            pass
