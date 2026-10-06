"""Podcasty -- `/podcasts/*`. Odděleně od hudby (žádné Listen, mixy,
ListenBrainz). Epizody hrají přes server: ten je průběžně přeposílá od
vydavatele přes Mullvad (i přetáčení / Range), telefon se k vydavateli
nepřipojuje a nic se dopředu nestahuje."""

from __future__ import annotations

import asyncio
import time

import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel
from sqlmodel import Session, select
from starlette.background import BackgroundTask

from app.auth import get_current_user
from app.db import get_session
from app.models import PodcastEpisode, PodcastProgress, PodcastShow, PodcastSubscription
from app.podcasts import feeds, service
from app.utils import utcnow

podcasts_router = APIRouter(prefix="/podcasts", tags=["podcasts"])


def _show_out(show: PodcastShow, subscribed: bool) -> dict:
    return {
        "id": show.id,
        "title": show.title,
        "author": show.author,
        "description": show.description,
        "artworkUrl": show.artwork_url,
        "subscribed": subscribed,
        "error": show.fetch_error,
    }


def _progress_map(session: Session, user_id: str, episode_ids: list[str]) -> dict[str, PodcastProgress]:
    if not episode_ids:
        return {}
    rows = session.exec(
        select(PodcastProgress).where(
            PodcastProgress.user_id == user_id, PodcastProgress.episode_id.in_(episode_ids)  # type: ignore[attr-defined]
        )
    ).all()
    return {p.episode_id: p for p in rows}


def _episode_out(ep: PodcastEpisode, show: PodcastShow | None, progress: PodcastProgress | None) -> dict:
    return {
        "id": ep.id,
        "showId": ep.show_id,
        "showTitle": show.title if show else None,
        "title": ep.title,
        "description": ep.description,
        "publishedAt": ep.published_at.isoformat() if ep.published_at else None,
        "durationMs": ep.duration_ms,
        "artworkUrl": ep.artwork_url or (show.artwork_url if show else None),
        "positionMs": progress.position_ms if progress else 0,
        "finished": bool(progress and progress.finished),
    }


def _subscribed_ids(session: Session, user_id: str) -> set[str]:
    return set(session.exec(select(PodcastSubscription.show_id).where(PodcastSubscription.user_id == user_id)).all())


@podcasts_router.get("/search")
async def search(q: str, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    q = q.strip()
    if len(q) < 2:
        return {"shows": []}
    results = await feeds.search(q)
    mine = {
        s.feed_url
        for s in session.exec(
            select(PodcastShow).where(PodcastShow.id.in_(_subscribed_ids(session, current[0])))  # type: ignore[attr-defined]
        ).all()
    }
    for r in results:
        r["subscribed"] = r["feedUrl"] in mine
    return {"shows": results}


class ShowIn(BaseModel):
    feedUrl: str
    title: str | None = None
    author: str | None = None
    artworkUrl: str | None = None
    itunesId: str | None = None


@podcasts_router.post("/shows")
async def open_show(body: ShowIn, current: tuple[str, str] = Depends(get_current_user)):
    """Kanál z výsledku hledání -> id v DB (načte RSS, když je potřeba).
    Neodebírá -- to je samostatná volba."""
    try:
        await feeds.check_url(body.feedUrl)
    except feeds.UnsafeUrl as e:
        raise HTTPException(status_code=422, detail=str(e))
    show_id = await asyncio.to_thread(
        service.get_or_create_show, body.feedUrl, body.model_dump(exclude={"feedUrl"})
    )
    return {"id": show_id}


@podcasts_router.get("/shows")
def my_shows(session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    """Odebírané pořady, u každého nejnovější epizoda."""
    ids = _subscribed_ids(session, current[0])
    out = []
    for show in session.exec(select(PodcastShow).where(PodcastShow.id.in_(ids))).all():  # type: ignore[attr-defined]
        latest = session.exec(
            select(PodcastEpisode)
            .where(PodcastEpisode.show_id == show.id)
            .order_by(PodcastEpisode.published_at.desc())  # type: ignore[union-attr]
        ).first()
        item = _show_out(show, True)
        item["latestAt"] = latest.published_at.isoformat() if latest and latest.published_at else None
        out.append(item)
    out.sort(key=lambda s: s["latestAt"] or "", reverse=True)
    return {"shows": out}


@podcasts_router.get("/shows/{show_id}")
async def show_detail(show_id: str, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    show = session.get(PodcastShow, show_id)
    if show is None:
        raise HTTPException(status_code=404, detail="pořad nenalezen")
    if service.is_stale(show):
        await service.refresh(show.id, show.feed_url)
        session.expire_all()
        show = session.get(PodcastShow, show_id)
    episodes = session.exec(
        select(PodcastEpisode)
        .where(PodcastEpisode.show_id == show_id)
        .order_by(PodcastEpisode.published_at.desc())  # type: ignore[union-attr]
        .limit(200)
    ).all()
    progress = _progress_map(session, current[0], [e.id for e in episodes])
    return {
        **_show_out(show, show_id in _subscribed_ids(session, current[0])),
        "episodes": [_episode_out(e, show, progress.get(e.id)) for e in episodes],
    }


@podcasts_router.put("/shows/{show_id}/subscription")
def subscribe(show_id: str, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    if session.get(PodcastShow, show_id) is None:
        raise HTTPException(status_code=404, detail="pořad nenalezen")
    if show_id not in _subscribed_ids(session, current[0]):
        session.add(PodcastSubscription(user_id=current[0], show_id=show_id))
        session.commit()
    return {"subscribed": True}


@podcasts_router.delete("/shows/{show_id}/subscription")
def unsubscribe(show_id: str, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)):
    for sub in session.exec(
        select(PodcastSubscription).where(PodcastSubscription.user_id == current[0], PodcastSubscription.show_id == show_id)
    ).all():
        session.delete(sub)
    session.commit()
    return {"subscribed": False}


@podcasts_router.get("/new")
def new_episodes(
    limit: int = 30, session: Session = Depends(get_session), current: tuple[str, str] = Depends(get_current_user)
):
    """Nejnovější epizody odebíraných pořadů (Domů mluveného slova) a
    rozposlouchané epizody."""
    ids = _subscribed_ids(session, current[0])
    shows = {s.id: s for s in session.exec(select(PodcastShow).where(PodcastShow.id.in_(ids))).all()}  # type: ignore[attr-defined]
    episodes = session.exec(
        select(PodcastEpisode)
        .where(PodcastEpisode.show_id.in_(ids))  # type: ignore[attr-defined]
        .order_by(PodcastEpisode.published_at.desc())  # type: ignore[union-attr]
        .limit(max(1, min(limit, 100)))
    ).all()
    started = session.exec(
        select(PodcastProgress)
        .where(PodcastProgress.user_id == current[0], PodcastProgress.finished == False)  # noqa: E712
        .order_by(PodcastProgress.updated_at.desc())  # type: ignore[attr-defined]
        .limit(10)
    ).all()
    in_progress = []
    for p in started:
        ep = session.get(PodcastEpisode, p.episode_id)
        if ep is not None and p.position_ms > 0:
            show = shows.get(ep.show_id) or session.get(PodcastShow, ep.show_id)
            in_progress.append(_episode_out(ep, show, p))
    progress = _progress_map(session, current[0], [e.id for e in episodes])
    return {
        "inProgress": in_progress,
        "episodes": [_episode_out(e, shows.get(e.show_id), progress.get(e.id)) for e in episodes],
    }


_final_urls: dict[str, tuple[str, float]] = {}

_PASS_HEADERS = ("content-type", "content-length", "content-range", "accept-ranges", "last-modified", "etag")


@podcasts_router.get("/episodes/{episode_id}/stream")
async def stream_episode(episode_id: str, request: Request, session: Session = Depends(get_session)):
    ep = session.get(PodcastEpisode, episode_id)
    if ep is None:
        raise HTTPException(status_code=404, detail="epizoda nenalezena")
    headers = {"Range": request.headers["range"]} if request.headers.get("range") else None
    client = httpx.AsyncClient(
        proxy=feeds.proxy(), timeout=httpx.Timeout(30.0, read=90.0), headers={"User-Agent": "Opentify-Podcasts/1.0"}
    )
    # Vydavatelé vedou přes řetěz přesměrování (měření poslechů) -- ~3 s.
    # Konečnou adresu si chvíli pamatovat: přetáčení (nový Range) pak hned.
    cached = _final_urls.get(episode_id)
    url = cached[0] if cached and cached[1] > time.monotonic() else ep.audio_url
    try:
        resp = await feeds.safe_get(client, url, headers=headers, stream=True)
        if resp.status_code >= 400 and url != ep.audio_url:
            await resp.aclose()
            resp = await feeds.safe_get(client, ep.audio_url, headers=headers, stream=True)
    except (feeds.UnsafeUrl, httpx.HTTPError):
        await client.aclose()
        raise HTTPException(status_code=502, detail="epizodu se nepodařilo načíst od vydavatele")
    _final_urls[episode_id] = (str(resp.url), time.monotonic() + 600)
    if len(_final_urls) > 500:
        _final_urls.pop(next(iter(_final_urls)))
    ctype = resp.headers.get("content-type", "").split(";")[0].strip().lower()
    if resp.status_code not in (200, 206) or not (
        ctype.startswith("audio/") or ctype in ("application/octet-stream", "video/mp4", "binary/octet-stream")
    ):
        await resp.aclose()
        await client.aclose()
        raise HTTPException(status_code=502, detail="vydavatel nevrátil zvuk")

    async def close() -> None:
        await resp.aclose()
        await client.aclose()

    out_headers = {k: v for k, v in resp.headers.items() if k.lower() in _PASS_HEADERS}
    if ctype in ("application/octet-stream", "binary/octet-stream"):
        out_headers["content-type"] = "audio/mpeg"
    return StreamingResponse(
        resp.aiter_raw(), status_code=resp.status_code, headers=out_headers, background=BackgroundTask(close)
    )


class ProgressIn(BaseModel):
    positionMs: int
    finished: bool = False


@podcasts_router.put("/episodes/{episode_id}/progress")
def save_progress(
    episode_id: str,
    body: ProgressIn,
    session: Session = Depends(get_session),
    current: tuple[str, str] = Depends(get_current_user),
):
    if session.get(PodcastEpisode, episode_id) is None:
        raise HTTPException(status_code=404, detail="epizoda nenalezena")
    p = session.exec(
        select(PodcastProgress).where(PodcastProgress.user_id == current[0], PodcastProgress.episode_id == episode_id)
    ).first() or PodcastProgress(user_id=current[0], episode_id=episode_id)
    p.position_ms, p.finished, p.updated_at = max(0, body.positionMs), body.finished, utcnow()
    session.add(p)
    session.commit()
    return {"ok": True}
