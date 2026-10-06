"""Podcasty ze Spotify historie ("Extended streaming history").

Z exportu se vezme jen pořad, epizoda, čas a délka přehrání (sečteno po
epizodách). Nic se samo neodebírá -- appka ukáže "Poslouchal jsi na Spotify"
a uživatel si vybere. Po odběru se epizody, které na Spotify doposlouchal,
označí jako přehrané. Do hudebních poslechů (Wrapped, mixy) se nepočítá.
"""

from __future__ import annotations

import io
import json
import re
import unicodedata
import zipfile
from collections import defaultdict
from datetime import datetime, timedelta

from sqlmodel import Session, delete, select

from app.db import engine
from app.models import (
    PodcastEpisode,
    PodcastListenHistory,
    PodcastNameMatch,
    PodcastProgress,
    PodcastShow,
    PodcastSubscription,
)
from app.utils import utcnow

SOURCE = "spotify"
# Doposlouchaná epizoda: aspoň tolik délky (nebo 20 min, když délku neznáme).
FINISHED_SHARE = 0.85
FINISHED_UNKNOWN_MS = 20 * 60 * 1000
RECHECK_MISSING = timedelta(days=30)


def read_spotify_zip(raw: bytes) -> list[dict]:
    rows: list[dict] = []
    from app.uploads import check_zip

    with zipfile.ZipFile(io.BytesIO(raw)) as zf:
        check_zip(zf)
        for info in zf.infolist():
            name = info.filename.rsplit("/", 1)[-1]
            if not (name.startswith("Streaming_History_Audio") and name.endswith(".json")):
                continue
            for r in json.loads(zf.read(info).decode("utf-8-sig")):
                show, episode = r.get("episode_show_name"), r.get("episode_name")
                if show and episode and r.get("ts"):
                    rows.append({"show": show, "episode": episode, "ts": r["ts"], "ms": int(r.get("ms_played") or 0)})
    return rows


def import_rows(user_id: str, rows: list[dict], source: str = SOURCE) -> dict:
    """Nahradí dřívější import z téže služby (nic se nezdvojí)."""
    agg: dict[tuple[str, str], dict] = defaultdict(lambda: {"ms": 0, "plays": 0, "last": None})
    for r in rows:
        a = agg[(r["show"].strip()[:300], r["episode"].strip()[:500])]
        a["ms"] += r["ms"]
        a["plays"] += 1
        ts = datetime.fromisoformat(r["ts"].replace("Z", "+00:00"))
        a["last"] = max(a["last"], ts) if a["last"] else ts
    with Session(engine) as session:
        session.exec(
            delete(PodcastListenHistory).where(  # type: ignore[arg-type]
                PodcastListenHistory.user_id == user_id, PodcastListenHistory.source == source
            )
        )
        for (show, episode), a in agg.items():
            session.add(
                PodcastListenHistory(
                    user_id=user_id, source=source, show_name=show, episode_name=episode,
                    ms_played=a["ms"], plays=a["plays"], last_played_at=a["last"],
                )
            )
        session.commit()
    return {"podcastShows": len({s for s, _ in agg}), "podcastEpisodes": len(agg)}


def import_spotify(user_id: str, raw: bytes) -> dict:
    rows = read_spotify_zip(raw)
    return import_rows(user_id, rows) if rows else {"podcastShows": 0, "podcastEpisodes": 0}


def fold(text: str) -> str:
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(c for c in text if not unicodedata.combining(c))
    return re.sub(r"[^a-z0-9]+", " ", text).strip()


def _best(name: str, results: list[dict]) -> dict | None:
    target = fold(name)
    for r in results:
        if fold(r["title"]) == target:
            return r
    for r in results:  # "Buchty" vs "Buchty podcast", "X | Y" apod.
        t = fold(r["title"])
        if t.startswith(target + " ") or target.startswith(t + " "):
            return r
    return None


async def match_pending(r, per_run: int = 15) -> int:
    """Údržba (worker): napárovat názvy pořadů z historie na katalog --
    pomalu (Apple pouští ~20 hledání za minutu), pár za běh."""
    if not await r.set("podcasts:match", "1", nx=True, ex=120):
        return 0
    try:
        with Session(engine) as session:
            totals: dict[str, int] = defaultdict(int)
            for name, ms in session.exec(select(PodcastListenHistory.show_name, PodcastListenHistory.ms_played)).all():
                totals[name] += ms
            done = set(session.exec(select(PodcastNameMatch.name).where(PodcastNameMatch.name.in_(list(totals)))).all())  # type: ignore[attr-defined]
        # Nejposlouchanější první -- ty uživatel v seznamu uvidí nahoře.
        todo = sorted((n for n in totals if n not in done), key=lambda n: -totals[n])[:per_run]
        if todo:
            await match_names(todo, pause_s=3.0)
        return len(todo)
    finally:
        await r.delete("podcasts:match")


async def match_names(names: list[str], pause_s: float = 0.0) -> dict[str, PodcastNameMatch]:
    """Název -> pořad v katalogu (uloží se; nenalezené se zkusí po 30 dnech)."""
    import asyncio

    from app.podcasts import feeds

    with Session(engine) as session:
        known = {m.name: m for m in session.exec(select(PodcastNameMatch).where(PodcastNameMatch.name.in_(names))).all()}  # type: ignore[attr-defined]
        for m in known.values():
            session.expunge(m)
    now = utcnow()
    todo = []
    for n in names:
        m = known.get(n)
        checked = m.checked_at if m and m.checked_at.tzinfo else (m.checked_at.replace(tzinfo=now.tzinfo) if m else None)
        if m is None or (m.feed_url is None and checked is not None and now - checked > RECHECK_MISSING):
            todo.append(n)
    for i, n in enumerate(todo):
        if i and pause_s:
            await asyncio.sleep(pause_s)
        try:
            hit = _best(n, await feeds.search(n, limit=10))
        except Exception:  # noqa: BLE001 -- zkusí se příště
            continue
        with Session(engine) as session:
            m = session.get(PodcastNameMatch, n) or PodcastNameMatch(name=n)
            m.feed_url = hit["feedUrl"] if hit else None
            m.title = hit["title"] if hit else None
            m.author = hit.get("author") if hit else None
            m.artwork_url = hit.get("artworkUrl") if hit else None
            m.itunes_id = hit.get("itunesId") if hit else None
            m.checked_at = now
            session.add(m)
            session.commit()
            session.refresh(m)
            session.expunge(m)
            known[n] = m
    return known


def overview(user_id: str) -> list[dict]:
    """Pořady z historie, nejvíc poslouchané první (bez párování)."""
    with Session(engine) as session:
        rows = session.exec(select(PodcastListenHistory).where(PodcastListenHistory.user_id == user_id)).all()
    shows: dict[str, dict] = {}
    for r in rows:
        s = shows.setdefault(r.show_name, {"name": r.show_name, "ms": 0, "episodes": 0, "last": None})
        s["ms"] += r.ms_played
        s["episodes"] += 1
        if r.last_played_at and (s["last"] is None or r.last_played_at > s["last"]):
            s["last"] = r.last_played_at
    return sorted(shows.values(), key=lambda s: s["ms"], reverse=True)


def mark_finished_from_history(user_id: str, show_id: str) -> int:
    """Epizody pořadu doposlouchané na Spotify -> přehrané (jen kde ještě
    žádná pozice není -- poslech v appce má přednost)."""
    with Session(engine) as session:
        show = session.get(PodcastShow, show_id)
        if show is None:
            return 0
        names = [
            m.name
            for m in session.exec(select(PodcastNameMatch).where(PodcastNameMatch.feed_url == show.feed_url)).all()
        ] or [show.title]
        history = session.exec(
            select(PodcastListenHistory).where(
                PodcastListenHistory.user_id == user_id,
                PodcastListenHistory.show_name.in_(names),  # type: ignore[attr-defined]
            )
        ).all()
        if not history:
            return 0
        by_title = {fold(h.episode_name): h for h in history}
        episodes = session.exec(select(PodcastEpisode).where(PodcastEpisode.show_id == show_id)).all()
        have = {
            p.episode_id
            for p in session.exec(
                select(PodcastProgress).where(
                    PodcastProgress.user_id == user_id,
                    PodcastProgress.episode_id.in_([e.id for e in episodes]),  # type: ignore[attr-defined]
                )
            ).all()
        }
        marked = 0
        for e in episodes:
            h = by_title.get(fold(e.title))
            if h is None or e.id in have:
                continue
            done = h.ms_played >= (e.duration_ms * FINISHED_SHARE if e.duration_ms else FINISHED_UNKNOWN_MS)
            if done:
                session.add(PodcastProgress(user_id=user_id, episode_id=e.id, position_ms=0, finished=True,
                                            updated_at=h.last_played_at or utcnow()))
                marked += 1
        session.commit()
        return marked


def subscribed_show_ids(user_id: str) -> set[str]:
    with Session(engine) as session:
        return set(session.exec(select(PodcastSubscription.show_id).where(PodcastSubscription.user_id == user_id)).all())
