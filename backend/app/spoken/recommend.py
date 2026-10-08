"""Doporučení pro mluvené slovo (Domů): podcasty a audioknihy.

Podcasty: pořady ze Spotify historie, které ještě neodebíráš; populární
české pořady ve stejných žánrech jako ty odebírané (žebříčky Apple);
jinak celkový český žebříček. Knihy: další od autorů, které posloucháš;
populární nové audioknihy na SkTorrentu (nejvíc zdrojů). Vše přes Mullvad,
výsledek v mezipaměti, u každé položky krátké "proč".
"""

from __future__ import annotations

import asyncio
import logging
from collections import Counter

import httpx
from sqlmodel import Session, select

from app.db import engine
from app.models import PodcastListenHistory, PodcastNameMatch, PodcastShow, PodcastSubscription, SpokenBook, SpokenProgress
from app.podcasts import feeds
from app.spoken import sktorrent

logger = logging.getLogger(__name__)

_GENRE_NAMES = {
    "1489": "Zprávy", "1324": "Společnost a kultura", "1310": "Hudba", "1301": "Umění", "1303": "Komedie",
    "1304": "Vzdělávání", "1309": "TV a film", "1318": "Technologie", "1321": "Byznys", "1488": "True crime",
    "1487": "Historie", "1533": "Věda", "1545": "Sport", "1512": "Zdraví", "1314": "Náboženství",
    "1483": "Fikce", "1502": "Volný čas", "1305": "Děti a rodina", "1511": "Vláda",
}
_MAX = 12


async def _itunes_lookup(client: httpx.AsyncClient, ids: list[str]) -> list[dict]:
    if not ids:
        return []
    resp = await client.get("https://itunes.apple.com/lookup", params={"id": ",".join(ids[:50]), "country": "cz"})
    resp.raise_for_status()
    return [r for r in resp.json().get("results", []) if r.get("feedUrl")]


async def _chart(client: httpx.AsyncClient, genre: str | None) -> list[str]:
    url = "https://itunes.apple.com/cz/rss/toppodcasts/limit=25" + (f"/genre={genre}" if genre else "") + "/json"
    resp = await client.get(url)
    resp.raise_for_status()
    return [e["id"]["attributes"]["im:id"] for e in resp.json().get("feed", {}).get("entry", []) if e.get("id")]


def _podcast_item(r: dict, reason: str) -> dict:
    return {
        "title": r.get("collectionName") or r.get("title") or "",
        "author": r.get("artistName") or r.get("author"),
        "artworkUrl": r.get("artworkUrl600") or r.get("artworkUrl100") or r.get("artworkUrl"),
        "feedUrl": r.get("feedUrl"),
        "itunesId": str(r.get("collectionId") or r.get("itunesId") or ""),
        "reason": reason,
    }


async def podcasts_for(user_id: str) -> list[dict]:
    def mine() -> tuple[set[str], set[str], list[dict]]:
        with Session(engine) as s:
            shows = [
                s.get(PodcastShow, sid)
                for sid in s.exec(select(PodcastSubscription.show_id).where(PodcastSubscription.user_id == user_id)).all()
            ]
            feeds_ = {x.feed_url for x in shows if x}
            itunes = {x.itunes_id for x in shows if x and x.itunes_id}
            # Ze Spotify historie: nejposlouchanější, ještě neodebírané.
            totals: Counter = Counter()
            for name, ms in s.exec(
                select(PodcastListenHistory.show_name, PodcastListenHistory.ms_played).where(
                    PodcastListenHistory.user_id == user_id
                )
            ).all():
                totals[name] += ms
            history = []
            for name, _ms in totals.most_common(30):
                m = s.get(PodcastNameMatch, name)
                if m and m.feed_url and m.feed_url not in feeds_:
                    history.append({"title": m.title, "author": m.author, "artworkUrl": m.artwork_url,
                                    "feedUrl": m.feed_url, "itunesId": m.itunes_id})
                    if m.itunes_id:
                        itunes.add(m.itunes_id)
            return feeds_, itunes, history

    subscribed, itunes_ids, history = await asyncio.to_thread(mine)
    out: list[dict] = [_podcast_item(h, "Poslouchal jsi na Spotify") for h in history[:4]]
    seen = set(subscribed) | {o["feedUrl"] for o in out}
    try:
        async with httpx.AsyncClient(proxy=feeds.proxy(), timeout=15, headers={"User-Agent": "Opentify-Podcasts/1.0"}) as c:
            genres: Counter = Counter()
            for r in await _itunes_lookup(c, sorted(itunes_ids)):
                for g in r.get("genreIds") or []:
                    if g != "26":
                        genres[g] += 1
            picks = [(g, f"Oblíbené v žánru {_GENRE_NAMES.get(g, 'tvých pořadů')}") for g, _ in genres.most_common(2)]
            if not picks:
                picks = [(None, "Oblíbené v Česku")]
            per_genre = max(3, (_MAX - len(out)) // len(picks))
            for genre, reason in picks:
                ids = [i for i in await _chart(c, genre) if i not in itunes_ids][:10]
                added = 0
                for r in await _itunes_lookup(c, ids):
                    if r["feedUrl"] not in seen and added < per_genre:
                        seen.add(r["feedUrl"])
                        out.append(_podcast_item(r, reason))
                        added += 1
    except (httpx.HTTPError, ValueError, KeyError) as e:
        logger.warning("doporučení podcastů: %s", e)
    return out[:_MAX]


async def books_for(user_id: str) -> list[dict]:
    from app.models import SpokenFavorite
    from app.spoken.catalog import fold, parse_release

    def mine() -> tuple[set[str], list[str], set[str]]:
        with Session(engine) as s:
            books = s.exec(select(SpokenBook)).all()
            have = {b.source_ref.split(":")[0] for b in books}
            listened = set(s.exec(select(SpokenProgress.book_id).where(SpokenProgress.user_id == user_id)).all())
            favs = s.exec(select(SpokenFavorite).where(SpokenFavorite.user_id == user_id)).all()
            fav_books = {f.ref for f in favs if f.kind == "book"}
            authors: Counter = Counter()
            # Autoři se srdíčkem napřed (vlastní volba), pak poslouchaní.
            for f in favs:
                if f.kind == "person" and f.ref.startswith("author:") and f.name:
                    authors[f.name] += 10
            by_id = {b.id: b for b in books}
            for bid in listened:
                b = by_id.get(bid)
                if b and b.author:
                    authors[b.author] += 1
            if not authors:  # zatím nic neposlouchal -> autoři knih, které si stáhl
                for b in books:
                    if b.requested_by_user_id == user_id and b.author:
                        authors[b.author] += 1
            # Knihy, které profil má / poslouchá / dočetl -- jiné vydání téže
            # knihy nedoporučovat (souhrn 8. 10. #13).
            mine_titles = {
                fold(b.title) for b in books
                if b.id in listened or b.id in fav_books or b.requested_by_user_id == user_id
            } - {""}
            return have, [a for a, _ in authors.most_common(2)], mine_titles

    have, authors, mine_titles = await asyncio.to_thread(mine)
    out: list[dict] = []
    seen = set(have)

    def another_edition(title: str) -> bool:
        parts = {fold(p) for p in parse_release(title)["parts"]}
        return bool(parts & mine_titles)

    def add(releases, reason: str, limit: int) -> None:
        n = 0
        for r in sorted(releases, key=lambda r: -r.seeders):
            if r.infohash in seen or r.seeders == 0 or another_edition(r.title):
                continue
            seen.add(r.infohash)
            out.append({**r.to_json(), "reason": reason})
            n += 1
            if n >= limit:
                break

    try:
        for author in authors:
            add(await sktorrent.search(author), f"Od autora {author}", 4)
        add(await sktorrent.latest(), "Populární teď", _MAX)
    except httpx.HTTPError as e:
        logger.warning("doporučení knih: %s", e)
    return out[:_MAX]
