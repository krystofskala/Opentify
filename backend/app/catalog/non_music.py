"""Vydání, která nejsou hudba: rozhovory, mluvené slovo, audioknihy.

MusicBrainz je značí sekundárním typem ("The Profile" od Lany Del Rey =
Other + Interview: 14 "skladeb" po 6--16 minutách pojmenovaných jako její
písně). Deezer totéž vede jako obyčejné album bez žánru -- pozná se jen
podle stejnojmenného MB vydání nebo podle názvu. Taková vydání se v
diskografii neukazují a worker je nestahuje (rozhovor nesmí hrát místo
písně).
"""

from __future__ import annotations

import re

from app.models import Release

NON_MUSIC_TYPES = frozenset({"interview", "spokenword", "audiobook", "audio drama"})

_TITLE_RE = re.compile(
    r"\b(interviews?|in (?:his|her|their) own words|spoken word|audio ?biography|audiobook|"
    r"talking about|the lowdown|rozhovory?)\b",
    re.IGNORECASE,
)


# "Symphonies Nos. 1-9 & Interviews" = hudba s bonusem, ne rozhovor.
_MIXED_RE = re.compile(r"(?:&|\+|\band\b|\bwith\b|\ba\b)\s*(?:rare\s+)?(?:interviews?|rozhovory?)\b", re.IGNORECASE)


def mentions_interview(title: str | None) -> bool:
    """Široké síto pro kandidáty k ověření v MusicBrainz (i smíšená vydání)."""
    return bool(title and _TITLE_RE.search(title))


def is_non_music_title(title: str | None) -> bool:
    return bool(title and _TITLE_RE.search(title) and not _MIXED_RE.search(title))


def is_non_music(release: Release | None) -> bool:
    if release is None:
        return False
    refs = release.external_refs or {}
    # "junk" = pirátské vydání, které nejde nikdy obsloužit správně (koncertní
    # bootleg, falešná výběrovka "Beatles Unpublished") -- stejně skryté.
    return bool(refs.get("nonMusic") or refs.get("junk")) or is_non_music_title(release.title)


def mark_non_music(release: Release, secondary_types: list[str] | set[str]) -> bool:
    """Zapíše/smaže příznak podle MB sekundárních typů; True = změna."""
    flag = bool({t.lower() for t in secondary_types} & NON_MUSIC_TYPES)
    refs = dict(release.external_refs or {})
    if bool(refs.get("nonMusic")) == flag:
        return False
    if flag:
        refs["nonMusic"] = True
    else:
        refs.pop("nonMusic", None)
    release.external_refs = refs
    return True
