"""Hledání spoluprací: "Mark O'Connor Tony Rice" (i s překlepy, bez spojky)
-> skladby a alba, na kterých jsou OBA. Ověřuje se podle seznamu účinkujících
na Deezeru (`contributors` skladby / alba), ne jen podle shody slov --
"Drive" (Béla Fleck) s Tonym Ricem a Markem O'Connorem se tak najde, ale
skladba, kde jsou jen v názvu, ne.

Postup: dotaz se rozdělí na dva interprety (spojka "&", "+", ",", " a ",
" and ", " x ", " feat." -- jinak každé místo mezi slovy), každá půlka se
dohledá na Deezeru (přibližně, kvůli překlepům). Kandidáti: hledání skladeb
a alb "A B" a nejznámější skladby obou.
"""

from __future__ import annotations

import asyncio
import re
from difflib import SequenceMatcher
from typing import Any

from app.catalog.deezer import DeezerClient
from app.download_match import fold

_SEPARATORS = re.compile(r"\s*(?:&|\+|,|/|\s(?:a|and|x|feat\.?|ft\.?|s|with)\s)\s*", re.I)
_MIN_SIMILARITY = 0.55


def _norm(text: str) -> str:
    return re.sub(r"[^0-9a-z]+", "", fold(text))


def _similar(query: str, name: str) -> float:
    q, n = _norm(query), _norm(name)
    if not q or not n:
        return 0.0
    if q == n:
        return 1.0
    return SequenceMatcher(None, q, n).ratio()


def splits(query: str) -> list[tuple[str, str]]:
    """Možná rozdělení dotazu na dva interprety (nejpravděpodobnější první)."""
    query = " ".join(query.split())
    parts = [p for p in _SEPARATORS.split(query) if p.strip()]
    if len(parts) == 2:
        return [(parts[0].strip(), parts[1].strip())]
    words = query.split()
    if len(words) < 2 or len(words) > 8:
        return []
    out = [(" ".join(words[:i]), " ".join(words[i:])) for i in range(1, len(words))]
    # Dvě slova na jméno napřed ("Mark O'Connor" + "Tony Rice").
    out.sort(key=lambda s: abs(len(s[0].split()) - len(s[1].split())))
    return out


async def _artist(dz: DeezerClient, half: str) -> dict[str, Any] | None:
    """Deezer řadí podle oblíbenosti a překlepy zvládá ("marc ocoonr" ->
    Mark O'Connor), proto první dost podobný výsledek, ne ten s nejvyšší
    podobností písmen ("Marco Corona" je písmeny blíž, ale špatně)."""
    found = await dz.search_artist(half, limit=3, trust_name=False) or []
    return next((a for a in found if _similar(half, a.get("name") or "") >= _MIN_SIMILARITY), None)


async def resolve_pair(dz: DeezerClient, query: str) -> tuple[dict[str, Any], dict[str, Any]] | None:
    """Dva různé interprety z dotazu, nebo None (dotaz není spolupráce)."""
    # Celý dotaz je jméno jednoho interpreta ("Billy Strings", "Angus & Julia
    # Stone") -- žádná spolupráce.
    whole = await dz.search_artist(query, limit=3, trust_name=False) or []
    if any(_similar(query, a.get("name") or "") >= 0.85 for a in whole):
        return None
    for left, right in splits(query)[:4]:
        a, b = await asyncio.gather(_artist(dz, left), _artist(dz, right))
        if a and b and str(a.get("id")) != str(b.get("id")):
            return a, b
    return None


def _ids(items: list[dict[str, Any]] | None) -> set[str]:
    return {str(c.get("id")) for c in items or [] if c.get("id")}


async def find(dz: DeezerClient, a: dict[str, Any], b: dict[str, Any], limit: int = 30) -> dict[str, list[dict[str, Any]]]:
    """Deezer skladby a alba, kde jsou mezi účinkujícími oba."""
    pair = {str(a["id"]), str(b["id"])}
    q = f"{a.get('name')} {b.get('name')}"
    searched, top_a, top_b, albums = await asyncio.gather(
        dz.search_typed("track", q, 50),
        dz.artist_top(str(a["id"]), 100),
        dz.artist_top(str(b["id"]), 100),
        dz.search_typed("album", q, 15),
    )
    tracks: dict[str, dict[str, Any]] = {}
    # Nejznámější skladby obsahují účinkující rovnou.
    for t in [*(top_a or []), *(top_b or [])]:
        if t.get("id") and pair <= (_ids(t.get("contributors")) | {str((t.get("artist") or {}).get("id"))}):
            tracks.setdefault(str(t["id"]), t)
    # Z hledání se účinkující dotáhnou z detailu skladby.
    sem = asyncio.Semaphore(8)

    async def check_track(t: dict[str, Any]) -> None:
        if str(t.get("id")) in tracks:
            return
        async with sem:
            detail = await dz.track(str(t["id"])) or {}
        if pair <= _ids(detail.get("contributors")):
            tracks.setdefault(str(t["id"]), {**t, **detail})

    async def check_album(al: dict[str, Any]) -> dict[str, Any] | None:
        async with sem:
            detail = await dz.album(str(al["id"])) or {}
        return detail if pair <= _ids(detail.get("contributors")) else None

    await asyncio.gather(*(check_track(t) for t in (searched or [])[:30] if t.get("id")))
    album_hits = await asyncio.gather(*(check_album(al) for al in (albums or [])[:12] if al.get("id")))
    # Alba, ze kterých jsou nalezené skladby (spolupráce na cizím albu).
    found_albums = {str(al["id"]): al for al in album_hits if al}
    return {"tracks": list(tracks.values())[:limit], "albums": list(found_albums.values())}
