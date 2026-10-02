"""Scrobblování na Last.fm -- jen za profil, který si připojil VLASTNÍ účet
(Profil › Last.fm), a jen poslechy od připojení. Jiné profily na Last.fm
nic neposílají; veřejná data Last.fm (hledání, žánry...) mají všichni.

Připojení (desktopový tok Last.fm): `auth.getToken` -> uživatel token schválí
na last.fm -> `auth.getSession` vrátí trvalý session klíč profilu.
Scrobbly se posílají na pozadí ze stejné smyčky jako ListenBrainz
(app/listens.py); co selže, zkusí se znovu.
"""

from __future__ import annotations

import logging
from datetime import datetime, timedelta, timezone

from sqlmodel import Session, select

from app.catalog import lastfm
from app.db import engine
from app.models import AppUser, Artist, Listen, Recording, Release
from app.utils import utcnow

logger = logging.getLogger(__name__)

AUTH_URL = "https://www.last.fm/api/auth/?api_key={key}&token={token}"
_MAX_ATTEMPTS = 8
_BATCH = 50  # Last.fm bere max 50 scrobblů v jednom volání
_MAX_AGE = timedelta(days=13)  # starší než 14 dní Last.fm odmítá
_IMPORTED = ("spotify-history", "ytmusic-history", "applemusic-history")


async def start_connect() -> dict[str, str]:
    data = await lastfm.signed({"method": "auth.getToken"})
    token = data.get("token")
    if not token:
        raise lastfm.LastfmError("Last.fm nevrátil token")
    return {"token": token, "url": AUTH_URL.format(key=lastfm.api_key(), token=token)}


async def finish_connect(user_id: str, token: str) -> str:
    data = await lastfm.signed({"method": "auth.getSession", "token": token})
    session_info = data.get("session") or {}
    key, name = session_info.get("key"), session_info.get("name")
    if not key:
        raise lastfm.LastfmError("přihlášení na Last.fm nebylo potvrzené")
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        if user is None:
            raise lastfm.LastfmError("profil nenalezen")
        user.lastfm_session = key
        user.lastfm_user = name
        user.lastfm_connected_at = utcnow()
        session.add(user)
        session.commit()
    return name or ""


def disconnect(user_id: str) -> None:
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        if user is None:
            return
        user.lastfm_session = None
        user.lastfm_user = None
        user.lastfm_connected_at = None
        session.add(user)
        session.commit()


def _meta(session: Session, recording_id: str) -> dict[str, str] | None:
    rec = session.get(Recording, recording_id)
    artist = session.get(Artist, rec.artist_id) if rec and rec.artist_id else None
    if rec is None or artist is None or not rec.title:
        return None
    meta = {"artist": artist.name, "track": rec.title}
    release = session.get(Release, rec.release_id) if rec.release_id else None
    if release is not None and release.title:
        meta["album"] = release.title
    if rec.duration_ms:
        meta["duration"] = str(rec.duration_ms // 1000)
    return meta


async def now_playing(user_id: str, recording_id: str) -> None:
    with Session(engine) as session:
        user = session.get(AppUser, user_id)
        sk = user.lastfm_session if user else None
        meta = _meta(session, recording_id) if sk else None
    if not sk or meta is None:
        return
    try:
        await lastfm.signed({"method": "track.updateNowPlaying", "sk": sk, **meta}, post=True)
    except lastfm.LastfmError:
        pass


async def submit_pending() -> int:
    """Neodeslané poslechy profilů s připojeným Last.fm. Vrátí počet."""
    with Session(engine) as session:
        users = session.exec(
            select(AppUser).where(AppUser.lastfm_session.is_not(None))  # type: ignore[union-attr]
        ).all()
        targets = [(u.id, u.lastfm_session, u.lastfm_connected_at) for u in users]
    sent = 0
    for user_id, sk, since in targets:
        sent += await _submit_for(user_id, sk, since)
    return sent


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


async def _submit_for(user_id: str, sk: str, since: datetime | None) -> int:
    cutoff = utcnow() - _MAX_AGE
    if since is not None:
        cutoff = max(_aware(since), cutoff)
    with Session(engine) as session:
        pending = session.exec(
            select(Listen)
            .where(
                Listen.user_id == user_id,
                Listen.lastfm_submitted_at.is_(None),  # type: ignore[union-attr]
                Listen.played_at >= cutoff,
                (Listen.lastfm_attempts.is_(None)) | (Listen.lastfm_attempts < _MAX_ATTEMPTS),  # type: ignore[union-attr,operator]
                (Listen.source.is_(None)) | (Listen.source.not_in(_IMPORTED)),  # type: ignore[union-attr]
            )
            .order_by(Listen.played_at)
            .limit(_BATCH)
        ).all()
        params: dict[str, str] = {"method": "track.scrobble", "sk": sk}
        ids: list[str] = []
        for listen in pending:
            meta = _meta(session, listen.recording_id)
            if meta is None:
                listen.lastfm_attempts = _MAX_ATTEMPTS
                session.add(listen)
                continue
            i = len(ids)
            params[f"timestamp[{i}]"] = str(int(_aware(listen.played_at).timestamp()))
            for k, v in meta.items():
                params[f"{k}[{i}]"] = v
            ids.append(listen.id)
        session.commit()
    if not ids:
        return 0
    try:
        await lastfm.signed(params, post=True)
        ok = True
    except lastfm.LastfmError as exc:
        ok = False
        logger.warning("Last.fm: scrobble %d poslechů selhal (%s)", len(ids), exc)
    with Session(engine) as session:
        for listen_id in ids:
            listen = session.get(Listen, listen_id)
            if listen is None:
                continue
            if ok:
                listen.lastfm_submitted_at = utcnow()
            else:
                listen.lastfm_attempts = (listen.lastfm_attempts or 0) + 1
            session.add(listen)
        session.commit()
    return len(ids) if ok else 0
