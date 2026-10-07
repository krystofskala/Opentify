"""Český rozhlas (mujrozhlas.cz) jako zdroj audioknih a rozhlasových her.

Veřejné API `api.mujrozhlas.cz` (JSON:API): hledání (`/search?query=`),
seriály (četba na pokračování, hry na díly) a jejich díly s odkazem na mp3.
Díly jsou k poslechu jen po dobu práv -- co už nejde přehrát (nemá odkaz
ke stažení), se nenabízí. Stažené zůstává na serveru jako každá jiná kniha.

Ref vydání: "cro:s:<id seriálu>" nebo "cro:e:<id dílu>" (samostatná hra).
"""

from __future__ import annotations

import asyncio
import html
import json
import logging
import re
from pathlib import Path
from typing import Any, Callable

import httpx

logger = logging.getLogger(__name__)

API = "https://api.mujrozhlas.cz"
_UA = {"User-Agent": "Opentify/0.1 (self-hosted)"}
_SEARCH_TTL_S = 3600
_SHOW_TTL_S = 7 * 24 * 3600

# Pořady s knihami a hrami -- podle seznamu pořadů ČRo (8. 10. 2026);
# "Příběhy z kalendáře", "Seriál Radiožurnálu" apod. jsou publicistika.
_DRAMA_SHOW = re.compile(
    r"^(?:hra na |hra pro |minutová hra|rozhlasová hra|současná hra|sobotní drama|večerní drama|dramatapas|"
    r"radioseriál|rozhlasový seriál|rozehra|čistá hra|hry a četby|seriál$)",
    re.I,
)
_BOOK_SHOW = re.compile(
    r"četba|čtení|počteníčko|čtenářský deník|povídk|radiokniha|audioknihy|pohádk|k poslechu|svět poezie|"
    r"klasická povídka",
    re.I,
)


def _spoken_show(title: str | None) -> bool:
    return bool(title) and bool(_DRAMA_SHOW.search(title.strip()) or _BOOK_SHOW.search(title))
_NARRATOR = re.compile(r"\b(?:čte|načetl[a]?|v podání)\s+([A-ZÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ][\wáčďéěíňóřšťúůýž.-]+(?:\s+[A-ZÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ][\wáčďéěíňóřšťúůýž-]+){1,2})")
_TAGS = re.compile(r"<[^>]+>")


def is_ref(ref: str | None) -> bool:
    return bool(ref) and str(ref).startswith(("cro:s:", "cro:e:"))


def _client() -> httpx.AsyncClient:
    return httpx.AsyncClient(timeout=25, headers=_UA, follow_redirects=True)


def plain(text: str | None) -> str | None:
    """Popis z HTML na čistý text (odstavce zachované)."""
    if not text:
        return None
    text = re.sub(r"</p>\s*<p[^>]*>|<br\s*/?>", "\n", text, flags=re.I)
    text = html.unescape(_TAGS.sub("", text))
    text = re.sub(r"[ \t]+", " ", text)
    return re.sub(r"\n{3,}", "\n\n", text).strip()[:4000] or None


def split_title(title: str) -> dict:
    """"Zdeněk Jirotka: Saturnin. Slavný humoristický román…" ->
    autor "Zdeněk Jirotka", název "Saturnin". Bez dvojtečky jen název
    (bez reklamního dovětku za první větou)."""
    title = re.sub(r"\s+", " ", title or "").strip()
    author = None
    if ": " in title:
        head, rest = title.split(": ", 1)
        # Autor = 2-5 slov, každé s velkým písmenem nebo iniciálou.
        words = head.split()
        if 1 < len(words) <= 5 and all(w[:1].isupper() for w in words):
            author, title = head, rest
    main = re.split(r"(?<=[^\s.]{3})\. (?=[A-ZÁČĎÉĚÍŇÓŘŠŤÚŮÝŽ])", title, maxsplit=1)[0]
    main = re.sub(r"\s*\(\d+/\d+\)\s*$", "", main).strip(" .")
    return {"author": author, "title": main or title}


def _names(line: str, limit: int = 3) -> str | None:
    """"Andrea Elsnerová a Kamil Halbich" / "A, B, C a další" -> "A, B"."""
    line = re.sub(r"\s+a\s+(?:další|jiní)\b.*$", "", line.strip(" .")).strip()
    names = [n.strip(" .") for n in re.split(r",\s*|\s+a\s+", line) if n.strip(" .")]
    names = [n for n in names if 1 < len(n.split()) <= 4 and n[:1].isupper()]
    return ", ".join(names[:limit]) or None


def credits(description: str | None) -> dict:
    """Z popisu ČRo ("Čte: …", "Čtou: …", "Hrají: …", "Napsala: …") kdo
    čte / hraje a kdo knihu napsal."""
    out: dict[str, str | None] = {"narrator": None, "author": None}
    for line in (description or "").splitlines():
        head, sep, rest = line.partition(":")
        if not sep:
            continue
        key = head.strip().lower()
        if out["narrator"] is None and key in ("čte", "čtou", "hrají", "účinkují", "účinkuje", "hraje", "v hlavní roli", "v hlavních rolích"):
            out["narrator"] = _names(rest)
        elif out["author"] is None and key in ("napsal", "napsala", "autor", "autorka"):
            out["author"] = _names(rest, 2)
    if out["narrator"] is None and (m := _NARRATOR.search(description or "")):
        out["narrator"] = m.group(1).strip(" .,")
    return out


def _kind(show_title: str | None, title: str) -> str:
    from app.spoken.acquire import guess_kind

    if show_title and _DRAMA_SHOW.search(show_title.strip()):
        return "drama"
    return guess_kind(title)


def _mp3(attrs: dict) -> dict | None:
    """Odkaz ke stažení dílu. `till` je konec vysílání, ne práv -- díl bez
    práv prostě odkaz nemá (`audioLinks` prázdné)."""
    links = [link for link in attrs.get("audioLinks") or [] if link.get("linkType") == "download" and link.get("url")]
    if not links:
        return None
    best = max(links, key=lambda link: int(link.get("bitrate") or 0))
    return {"url": best["url"], "size": int(best.get("sizeInBytes") or 0), "duration": int(best.get("duration") or 0)}


async def _show_title(c: httpx.AsyncClient, show_id: str | None) -> str | None:
    if not show_id:
        return None
    from app.redis_bus import get_redis

    r = get_redis()
    key = f"spoken:cro:show:v1:{show_id}"
    if (cached := await r.get(key)) is not None:
        return cached.decode() if isinstance(cached, bytes) else cached
    try:
        resp = await c.get(f"{API}/shows/{show_id}")
        resp.raise_for_status()
        title = str(resp.json()["data"]["attributes"].get("title") or "")
    except (httpx.HTTPError, KeyError, ValueError):
        return None
    await r.set(key, title, ex=_SHOW_TTL_S)
    return title


def _show_id(item: dict) -> str | None:
    return ((item.get("relationships") or {}).get("show") or {}).get("data", {}).get("id")


async def _serial_episodes(c: httpx.AsyncClient, serial_id: str) -> list[dict]:
    resp = await c.get(f"{API}/serials/{serial_id}/episodes", params={"page[limit]": 100})
    resp.raise_for_status()
    out = []
    for ep in resp.json().get("data") or []:
        a = ep.get("attributes") or {}
        if (link := _mp3(a)) is None:
            continue
        out.append({"id": ep["id"], "part": a.get("part"), "title": a.get("title") or "", **link})
    out.sort(key=lambda e: (e["part"] is None, e["part"] or 0))
    return out


def _duration_text(seconds: int) -> str | None:
    if seconds <= 0:
        return None
    hours, minutes = divmod(seconds // 60, 60)
    return f"{hours} h {minutes} min" if hours else f"{minutes} min"


def _release(ref: str, title: str, show: str | None, episodes: list[dict], attrs: dict) -> dict:
    # Seriál, ze kterého jsou k poslechu jen některé díly (práva vypršela).
    total = max(int(attrs.get("totalParts") or 0), len(episodes))
    return {
        "source": "rozhlas",
        "ref": ref,
        "infohash": "",
        "title": title,
        "sizeBytes": sum(e["size"] for e in episodes) or None,
        "seeders": 1,
        "files": len(episodes),
        "uploader": show or "Český rozhlas",
        "durationText": _duration_text(sum(e["duration"] for e in episodes)),
        "coverUrl": (attrs.get("asset") or {}).get("url"),
        "kind": _kind(show, title),
        "totalParts": total,
        "complete": len(episodes) >= total,
        "description": plain(attrs.get("description")),
        "episodes": episodes,
    }


async def _cache_release(rel: dict) -> None:
    from app.redis_bus import get_redis

    await get_redis().set(f"spoken:cro:rel:v1:{rel['ref']}", json.dumps(rel), ex=_SEARCH_TTL_S)


def public(rel: dict) -> dict:
    """Pro appku bez seznamu dílů (ten je v obsahu vydání)."""
    return {k: v for k, v in rel.items() if k not in ("episodes", "description")}


async def search(q: str, limit: int = 12) -> list[dict]:
    """Knihy a hry z archivu, které jdou právě stáhnout: seriály (četba,
    hry na díly) i samostatné hry z pořadů s mluveným slovem."""
    async with _client() as c:
        serials_resp, episodes_resp = await asyncio.gather(
            c.get(f"{API}/search", params={"query": q, "filter[type]": "serial", "page[limit]": 20}),
            c.get(f"{API}/search", params={"query": q, "filter[type]": "episode", "page[limit]": 40}),
        )
        serials = [s for s in (serials_resp.json().get("data") or []) if (s.get("attributes") or {}).get("playable")]
        singles = [
            e for e in (episodes_resp.json().get("data") or [])
            if not ((e.get("relationships") or {}).get("serial") or {}).get("data") and _mp3(e.get("attributes") or {})
        ]
        show_ids = {sid for item in serials + singles if (sid := _show_id(item))}
        titles = dict(zip(show_ids, await asyncio.gather(*(_show_title(c, sid) for sid in show_ids))))

        async def serial_release(s: dict) -> dict | None:
            show = titles.get(_show_id(s))
            if not _spoken_show(show):
                return None
            try:
                episodes = await _serial_episodes(c, s["id"])
            except (httpx.HTTPError, ValueError):
                return None
            if not episodes:
                return None
            return _release(f"cro:s:{s['id']}", s["attributes"]["title"], show, episodes, s["attributes"])

        found = [r for r in await asyncio.gather(*(serial_release(s) for s in serials[:limit])) if r]
        for e in singles:
            show = titles.get(_show_id(e))
            if not _spoken_show(show):
                continue
            a = e["attributes"]
            ep = {"id": e["id"], "part": None, "title": a.get("title") or "", **_mp3(a)}  # type: ignore[dict-item]
            found.append(_release(f"cro:e:{e['id']}", a.get("title") or "", show, [ep], a))
    # Celé napřed (uživatel: "doporučit nejlepší shodu, co je celé").
    found = sorted(found, key=lambda r: not r["complete"])[:limit]
    for rel in found:
        await _cache_release(rel)
    return found


async def release(ref: str) -> dict | None:
    """Vydání podle refu (z mezipaměti hledání, jinak znovu z API)."""
    from app.redis_bus import get_redis

    if (cached := await get_redis().get(f"spoken:cro:rel:v1:{ref}")) is not None:
        return json.loads(cached)
    kind, _, rid = ref[4:].partition(":")
    async with _client() as c:
        try:
            if kind == "s":
                resp = await c.get(f"{API}/serials/{rid}")
                resp.raise_for_status()
                s = resp.json()["data"]
                show = await _show_title(c, _show_id(s))
                episodes = await _serial_episodes(c, rid)
                rel = _release(ref, s["attributes"]["title"], show, episodes, s["attributes"]) if episodes else None
            else:
                resp = await c.get(f"{API}/episodes/{rid}")
                resp.raise_for_status()
                e = resp.json()["data"]
                a = e["attributes"]
                link = _mp3(a)
                show = await _show_title(c, _show_id(e))
                ep = {"id": rid, "part": None, "title": a.get("title") or "", **(link or {})}
                rel = _release(ref, a.get("title") or "", show, [ep], a) if link else None
        except (httpx.HTTPError, KeyError, ValueError) as exc:
            logger.info("rozhlas %s: %s", ref, exc)
            return None
    if rel:
        await _cache_release(rel)
    return rel


def file_name(i: int, ep: dict) -> str:
    return f"{i + 1:03d}.mp3"


def part_titles(release_title: str, episodes: list[dict]) -> list[str]:
    """Názvy dílů do seznamu kapitol: bez opakovaného názvu seriálu; když
    zbude jen "(3/8)" nebo nic, tak "Část N"."""
    base = split_title(release_title)["title"].lower()
    rests = [split_title(ep.get("title") or "")["title"] for ep in episodes]
    if len(set(rests)) < len(rests):  # všechny díly stejně ("Anglické listy - První dojmy")
        rests = [""] * len(rests)
    return [
        rest if rest and rest.lower() != base else f"Část {ep.get('part') or i + 1}"
        for i, (ep, rest) in enumerate(zip(episodes, rests))
    ]


def download(episodes: list[dict], dest: Path, on_progress: Callable[[float], None], on_file: Callable[[Path], None]) -> None:
    """Díly postupně do `dest` (synchronní, ve vlákně). Hotový soubor
    (stejná velikost) se znovu nestahuje -- po restartu se pokračuje."""
    import os

    dest.mkdir(parents=True, exist_ok=True)
    proxy = os.environ.get("YTDLP_PROXY") or None
    total = sum(int(e.get("size") or 0) for e in episodes) or 1
    done = 0
    with httpx.Client(proxy=proxy, timeout=60, headers=_UA, follow_redirects=True) as c:
        for i, ep in enumerate(episodes):
            path = dest / file_name(i, ep)
            size = int(ep.get("size") or 0)
            if path.is_file() and size and path.stat().st_size == size:
                done += size
                on_progress(min(0.99, done / total))
                on_file(path)
                continue
            tmp = path.with_suffix(".part")
            with c.stream("GET", ep["url"]) as resp:
                resp.raise_for_status()
                with tmp.open("wb") as fh:
                    for chunk in resp.iter_bytes(1 << 16):
                        fh.write(chunk)
                        done += len(chunk)
                        on_progress(min(0.99, done / total))
            tmp.replace(path)
            on_file(path)


def fetch_cover(url: str, dest: Path) -> bool:
    import os

    proxy = os.environ.get("YTDLP_PROXY") or None
    try:
        with httpx.Client(proxy=proxy, timeout=20, headers=_UA, follow_redirects=True) as c:
            resp = c.get(url)
        if resp.status_code != 200 or not resp.content:
            return False
        dest.write_bytes(resp.content)
        return True
    except httpx.HTTPError:
        return False


def book_fields(rel: dict) -> dict[str, Any]:
    """Název, autor, interpret, druh a popis knihy z vydání."""
    parts = split_title(rel["title"])
    people = credits(rel.get("description"))
    return {
        "title": parts["title"][:300],
        "author": parts["author"] or people["author"],
        "narrator": people["narrator"],
        "kind": rel.get("kind") or "book",
        "description": rel.get("description"),
    }
