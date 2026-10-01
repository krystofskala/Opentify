"""Text skladeb přes veřejné LRCLIB API (https://lrclib.net/docs) — stejný
vzor jako `app/catalog/deezer.py`: tenký httpx adaptér + cache přes
`app.catalog.cache.cached_json`, aby opakovaný dotaz na tutéž skladbu
(mini bar i Now Playing screen ji můžou chtít znovu ve stejné relaci) nešel
pokaždé ven.

Používáme `/api/search`, ne přesný `/api/get` (ten vyžaduje bitově přesnou
délku skladby) — lokální soubory mají délku v tazích často mírně jinou než
LRCLIB záznam (jiný encoder/tagger), takže striktní shoda by zbytečně
propadala.

Výběr kandidáta podle DÉLKY: dřív se bral první výsledek se synchronizovaným
textem, a to byla často jiná verze (live, remaster, klip s intrem) -- časování
pak nesedělo vůbec (živě nahlášeno). Synchronizovaný text se teď vrací jen
od kandidáta, jehož délka sedí s naším souborem (± `_SYNC_TOLERANCE_S`);
jinak radši jen prostý text bez časování než špatně časovaný.
"""

from __future__ import annotations

import os
import re
from typing import Any

import httpx

from app.catalog.cache import cached_json

LRCLIB_BASE_URL = os.environ.get("LRCLIB_API_BASE", "https://lrclib.net/api")
LYRICS_TTL_SECONDS = 7 * 24 * 60 * 60  # text skladby se nemění, týden je bezpečný

_NOT_FOUND = {"not_found": True}
_SYNC_TOLERANCE_S = 3.0

_client = httpx.AsyncClient(base_url=LRCLIB_BASE_URL, timeout=10.0)

# " - 2004 Remaster", " (Remastered 2011)", " [Live]", " (feat. X)" ...
_TITLE_NOISE = re.compile(
    r"\s*(?:-\s*(?:\d{4}\s*)?(?:remaster(?:ed)?|mono|stereo|single version|radio edit)[^-]*$"
    r"|[\(\[][^\)\]]*(?:remaster|feat\.|ft\.|version|edit|mono|stereo)[^\)\]]*[\)\]])",
    re.IGNORECASE,
)


def clean_title(title: str) -> str:
    cleaned = _TITLE_NOISE.sub("", title).strip()
    return cleaned or title


class _SourceDown(Exception):
    """LRCLIB neodpověděl -- výsledek se NEUKLÁDÁ (dřív se výpadek uložil
    jako "text neexistuje" na týden; živě: Hot Milk – Wide Awake)."""


async def _search(params: dict[str, Any]) -> list[dict[str, Any]]:
    try:
        resp = await _client.get("/search", params=params)
        resp.raise_for_status()
        results = resp.json()
    except (httpx.TransportError, httpx.HTTPStatusError, ValueError) as exc:
        raise _SourceDown from exc
    return results if isinstance(results, list) else []


_ovh = httpx.AsyncClient(base_url="https://api.lyrics.ovh/v1", timeout=10.0)


async def _lyrics_ovh(artist_name: str | None, track_name: str) -> dict[str, Any] | None:
    """Záložní zdroj (lyrics.ovh): jen prostý text bez časování."""
    if not artist_name:
        return None
    from urllib.parse import quote

    try:
        resp = await _ovh.get(f"/{quote(artist_name, safe='')}/{quote(clean_title(track_name), safe='')}")
        text = (resp.json().get("lyrics") or "").strip() if resp.status_code == 200 else ""
    except (httpx.HTTPError, ValueError):
        return None
    # lyrics.ovh občas začíná řádkem "Paroles de la chanson ..." -- pryč.
    text = re.sub(r"^Paroles de la chanson[^\n]*\n", "", text).strip()
    return {"plain": text, "synced": None, "instrumental": False, "source": "lyrics.ovh"} if text else None


_netease: httpx.AsyncClient | None = None
# Řádky s autory/produkcí na začátku NetEase textů ("作词 : ...", "Composer: ...").
_NE_CREDIT = re.compile(
    r"^\[[0-9:.]+\]\s*(?:[^\x00-\x7f]{1,6}\s*[:：]|(?:lyrics?|composer|producer|arranger|written by)\b)",
    re.I,
)
# Hlavička "Interpret - Název" na začátku.
_NE_HEADER = re.compile(r"^\[00:0[0-2][.:]\d+\]\s*[^\[]* - [^\[]*$")


def _netease_client() -> httpx.AsyncClient | None:
    """NetEase Cloud Music (neoficiální API) -- jen přes Mullvad, domácí IP
    nevidí. Bez proxy se nevolá."""
    global _netease
    from app.apple_http import apple_proxy

    proxy = apple_proxy()
    if proxy is None:
        return None
    if _netease is None:
        _netease = httpx.AsyncClient(
            base_url="https://music.163.com/api",
            proxy=proxy,
            timeout=15.0,
            headers={"User-Agent": "Mozilla/5.0", "Referer": "https://music.163.com/"},
        )
    return _netease


def _ne_norm(text: str) -> str:
    return re.sub(r"[^\w]+", " ", (text or "").lower()).strip()


async def _lyrics_netease(artist_name: str | None, track_name: str, duration_s: float | None) -> dict[str, Any] | None:
    """Časovaný text z NetEase -- hodně i méně známých skladeb. Bere se jen
    přesná shoda interpreta a názvu (a délky, když ji známe)."""
    client = _netease_client()
    if client is None or not artist_name:
        return None
    title = clean_title(track_name)
    try:
        resp = await client.get("/search/get", params={"s": f"{artist_name} {title}", "type": 1, "limit": 10})
        songs = ((resp.json().get("result") or {}).get("songs") or []) if resp.status_code == 200 else []
    except (httpx.HTTPError, ValueError):
        return None
    want_artist, want_title = _ne_norm(artist_name), _ne_norm(title)
    candidates = [
        song
        for song in songs
        if _ne_norm(song.get("name", "")) == want_title
        and any(_ne_norm(a.get("name", "")) == want_artist for a in song.get("artists") or [])
        and (
            duration_s is None
            or not song.get("duration")
            or abs(song["duration"] / 1000 - duration_s) <= _SYNC_TOLERANCE_S
        )
    ]
    for song in candidates[:2]:
        try:
            data = (await client.get("/song/lyric", params={"id": song["id"], "lv": 1, "tv": -1})).json()
        except (httpx.HTTPError, ValueError):
            continue
        lrc = ((data.get("lrc") or {}).get("lyric") or "").strip()
        if not lrc or "纯音乐" in lrc:  # "čistě instrumentální"
            continue
        # Celé řádky pryč (autoři, hlavička) -- každý řádek má vlastní čas, takže
        # časování ostatních zůstane. Řádek jen s "." / prázdný = pauza (konec
        # sloky) -> prázdný řádek se SVÝM časem, jinak by předchozí verš svítil
        # přes celou mezihru.
        lines: list[str] = []
        for line in lrc.splitlines():
            stamps = re.match(r"^((?:\[[0-9:.]+\])+)", line.strip())
            if stamps is None or _NE_CREDIT.match(line) or _NE_HEADER.match(line):
                continue
            text = line.strip()[stamps.end():].strip()
            lines.append(f"{stamps.group(1)}{text}" if re.search(r"\w", text) else stamps.group(1))
        # Úvodní prázdné řádky nic nenesou.
        while lines and not re.sub(r"^(\[[0-9:.]+\])+", "", lines[0]):
            lines.pop(0)
        synced = "\n".join(lines).strip()
        plain = "\n".join(re.sub(r"^(\[[0-9:.]+\])+", "", line).strip() for line in lines).strip()
        if plain:
            return {"plain": plain, "synced": synced or None, "instrumental": False, "source": "netease"}
    return None


def _pick(results: list[dict[str, Any]], duration_s: float | None) -> dict[str, Any] | None:
    synced = [r for r in results if r.get("syncedLyrics")]
    if duration_s is None:
        best = synced[0] if synced else None
    else:
        fitting = [r for r in synced if abs(float(r.get("duration") or 0) - duration_s) <= _SYNC_TOLERANCE_S]
        best = min(fitting, key=lambda r: abs(float(r.get("duration") or 0) - duration_s), default=None)
    if best is not None:
        return {
            "plain": best.get("plainLyrics"),
            "synced": best.get("syncedLyrics"),
            "instrumental": bool(best.get("instrumental")),
            "matchedDuration": best.get("duration"),
        }
    plain = next((r for r in results if r.get("plainLyrics")), None)
    if plain is None:
        instrumental = next((r for r in results if r.get("instrumental")), None)
        return {"plain": None, "synced": None, "instrumental": True} if instrumental else None
    return {"plain": plain.get("plainLyrics"), "synced": None, "instrumental": bool(plain.get("instrumental"))}


async def fetch_lyrics(
    *,
    track_name: str,
    artist_name: str | None,
    album_name: str | None,
    duration_s: float | None = None,
) -> dict[str, Any] | None:
    duration_key = "" if duration_s is None else str(round(duration_s))
    cache_key = f"lyrics:v4:{artist_name or ''}:{track_name}:{duration_key}"

    async def fetch() -> dict[str, Any]:
        params: dict[str, Any] = {"track_name": track_name}
        if artist_name:
            params["artist_name"] = artist_name
        if album_name:
            params["album_name"] = album_name
        results = await _search(params)
        picked = _pick(results, duration_s)
        if picked is None or picked.get("synced") is None:
            # Druhý pokus: bez alba (kompilace/reedice se v LRCLIB jmenují
            # jinak) a s očištěným názvem ("- 2004 Remaster" apod.).
            params = {"track_name": clean_title(track_name)}
            if artist_name:
                params["artist_name"] = artist_name
            more = await _search(params)
            seen = {r.get("id") for r in results}
            merged = results + [r for r in more if r.get("id") not in seen]
            picked = _pick(merged, duration_s) or picked
        if picked is None or picked.get("synced") is None:
            # NetEase: časovaný text, když ho LRCLIB nemá (prostý z LRCLIB je
            # horší než časovaný odjinud).
            picked = await _lyrics_netease(artist_name, track_name, duration_s) or picked
        if picked is None:
            picked = await _lyrics_ovh(artist_name, track_name)
        return picked or _NOT_FOUND

    try:
        # "Nenalezeno" jen na krátko (EMPTY_TTL) -- texty do LRCLIB přibývají.
        result = await cached_json(
            cache_key, LYRICS_TTL_SECONDS, fetch, is_empty=lambda v: bool(v and v.get("not_found"))
        )
    except _SourceDown:
        return None
    if result is None or result.get("not_found"):
        return None
    return result
