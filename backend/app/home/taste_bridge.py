"""Most vkusu: objevy stylu / žánru podle CELÉHO vkusu profilu.

Společné pro všechny mixy "Tvůj mix · X" (stránky stylů v app/tags.py,
kategorie žánrů v app/home/category_mixes.py, Česká hudba přes styly).
Dřív se nové skladby braly jen od interpretů podobných těm pár, které ze
stylu už posloucháš (folkař s Eminemem dostal Dr. Dre a 50 Cent).

- **Profil stylů** z tvých poslechů (štítky Last.fm tvých interpretů: folk,
  písničkáři, jazz, akustické…) + jazyk/země ("czech" vybere český rap).
  Popisné nálepky ("female vocalists") ne.
- **Kandidáti**: nejposlouchanější interpreti stylu, jeho rodiny podstylů
  (rap -> jazz rap, conscious, český rap…) a tvých hlavních stylů, kteří ten
  styl zároveň výrazně hrají.
- **Shoda** = sdílené štítky vážené tvým profilem a vzácností štítku mezi
  kandidáty (IDF): co má každý rapper (pop, hip-hop), rozhoduje málo.
- **Popularita**: pod 10 tisíc posluchačů ne (šum ve štítcích, sloučená
  jména), nad tím roste váha s řádem.
- **"Hraje styl"** jen se silným štítkem (sloučené jméno "John Smith" folk
  100 / rap 22 ne) a bez slowed / sped up / instrumentálních verzí.
"""

from __future__ import annotations

import asyncio
import math
import random
import re

from app.catalog import lastfm
from app.catalog.artwork import _normalize

# Do profilu vkusu jen styly (tags.is_style) a jazyk/země posluchače.
PROFILE_EXTRA = {"czech", "slovak"}
JUNK_VERSION = re.compile(r"(slowed|sped up|speed up|reverb|nightcore|8d audio|instrumental)", re.I)
# Styl, který je jen jiným jménem hlavního žánru ("rap" = rodina hiphop).
FAMILY_ALIAS = {"rap": "hiphop", "hip-hop": "hiphop", "hip hop": "hiphop"}
# Podstyly, které na Last.fm znamenají i něco jiného ("lo-fi" = hlavně lo-fi
# indie: s ním se do rapu dostal Bill Callahan a Mountain Goats).
AMBIGUOUS_FAMILY = {"lo-fi"}
MIN_LISTENERS = 10_000


def is_junk_version(title: str | None) -> bool:
    return bool(JUNK_VERSION.search(title or ""))


def strong(tags: list[tuple[str, int]], t: str) -> bool:
    """Interpret styl opravdu hraje: silný štítek, nebo mezi jeho prvními
    třemi. Sloučená jména na Last.fm ("John Smith" folk 100 / rap 22) ne."""
    for i, (name, count) in enumerate(tags):
        if name.strip().lower() == t and (count >= 30 or (count >= 15 and i < 3)):
            return True
    return False


def family(styles: list[str]) -> list[str]:
    """Podstyly stejné rodiny (rap -> jazz rap, conscious, český rap…)."""
    from app.tags import SUBGENRES, parent_genres

    out: list[str] = []
    for t in styles:
        group = FAMILY_ALIAS.get(t) or (t if t in SUBGENRES else None)
        subs = SUBGENRES.get(group, ()) if group else tuple(x for g in parent_genres(t) for x in SUBGENRES.get(g, ()))
        out += [x for x in subs if x not in styles and x not in AMBIGUOUS_FAMILY]
    return list(dict.fromkeys(out))


def style_set(styles: list[str]) -> set[str]:
    """Styl + jeho jiná jména (rap = hip-hop = hip hop)."""
    out = set(styles)
    for t in styles:
        if t in FAMILY_ALIAS:
            out |= set(FAMILY_ALIAS)
    return out


def plays_style(tags: list[tuple[str, int]], styles: set[str], fam: list[str] = ()) -> bool:  # type: ignore[assignment]
    return any(strong(tags, s) for s in styles) or any(strong(tags, f) for f in fam)


def _profile_tag(tag: str) -> bool:
    from app.tags import is_style

    return is_style(tag) or tag.strip().lower() in PROFILE_EXTRA


async def _tags_of(name: str, sem: asyncio.Semaphore) -> list[tuple[str, int]]:
    async with sem:
        try:
            return await lastfm.artist_top_tags(name)
        except Exception:  # noqa: BLE001
            return []


async def _listeners(name: str, sem: asyncio.Semaphore) -> int:
    async with sem:
        try:
            return int(((await lastfm.artist_info(name)) or {}).get("listeners") or 0)
        except Exception:  # noqa: BLE001
            return 0


async def profile(weighted: list[tuple[str, float]], exclude: set[str], top: int = 100) -> dict[str, float]:
    """Styl -> podíl ve vkusu (součet 1) z `top` nejvážnějších interpretů."""
    sem = asyncio.Semaphore(6)
    head = [(n, w) for n, w in weighted if n][:top]
    out: dict[str, float] = {}
    for (_name, w), tags in zip(head, await asyncio.gather(*(_tags_of(n, sem) for n, _w in head))):
        for tag, count in tags:
            k = tag.strip().lower()
            if k not in exclude and count and _profile_tag(k):
                out[k] = out.get(k, 0.0) + w * count / 100
    total = sum(out.values()) or 1.0
    return {k: v / total for k, v in out.items()}


async def bridge(
    styles: list[str],
    weighted: list[tuple[str, float]],
    skip_names: set[str],
    rng: random.Random,
    n_artists: int = 12,
    per_artist: int = 2,
) -> list[dict[str, str]]:
    """(interpret, název) nejznámějších skladeb interpretů stylu, kteří
    nejvíc sedí k celému vkusu. `styles` = štítky Last.fm stylu / žánru,
    `weighted` = (jméno interpreta, váha) z vkusu profilu, nejvážnější první,
    `skip_names` = normalizovaná jména, která už v mixu jsou."""
    from app.tags import is_style

    styles = [s.strip().lower() for s in styles if s]
    names = style_set(styles)
    fam = family(styles)
    prof = await profile(weighted, names | set(fam))
    if not prof:
        return []
    sem = asyncio.Semaphore(6)
    mine = [k for k in sorted(prof, key=lambda k: -prof[k]) if is_style(k)][:3]
    lists = await asyncio.gather(
        *(lastfm.tag_top_artists(s, 200) for s in styles),
        *(lastfm.tag_top_artists(k, 100) for k in mine),
        *(lastfm.tag_top_artists(f, 50) for f in fam),
        return_exceptions=True,
    )
    candidates = [
        n for n in dict.fromkeys(n for lst in lists if isinstance(lst, list) for n in lst)
        if _normalize(n) not in skip_names
    ]
    cand_tags = [
        (n, tags) for n, tags in zip(candidates, await asyncio.gather(*(_tags_of(n, sem) for n in candidates)))
        if plays_style(tags, names, fam)
    ]
    if not cand_tags:
        return []
    df: dict[str, int] = {}
    for _n, tags in cand_tags:
        for tag, _c in tags:
            df[tag.strip().lower()] = df.get(tag.strip().lower(), 0) + 1
    idf = {k: math.log((1 + len(cand_tags)) / (1 + v)) for k, v in df.items()}
    ignore = names | set(fam)
    scored: list[tuple[float, str]] = []
    for n, tags in cand_tags:
        fit = sum(
            prof.get(k, 0.0) * idf.get(k, 0.0) * count / 100
            for tag, count in tags
            if (k := tag.strip().lower()) not in ignore and _profile_tag(k)
        )
        if fit > 0:
            scored.append((fit * (0.8 + 0.4 * rng.random()), n))
    scored.sort(reverse=True)
    head = scored[: n_artists * 3]
    counts = await asyncio.gather(*(_listeners(n, sem) for _f, n in head))
    rescored = sorted(
        ((f * min(1.0, max(0.25, (math.log10(c) - 3.5) / 2.5)), n) for (f, n), c in zip(head, counts) if c >= MIN_LISTENERS),
        reverse=True,
    )
    picked = [n for _f, n in rescored[:n_artists]]
    tracks = await asyncio.gather(*(lastfm.artist_top_tracks(n, 10) for n in picked), return_exceptions=True)
    out: list[dict[str, str]] = []
    for lst in tracks:
        if isinstance(lst, list):
            clean = [x for x in lst if not is_junk_version(x.get("title"))]
            out += rng.sample(clean, min(per_artist, len(clean)))
    return out
