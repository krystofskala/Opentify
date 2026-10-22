"""Jeden filtr pro všechna skládání (OP-ALG1, Kryštof 22. 10.: "co se bere
odkud, s čím, kdy a pro co" bylo v každé funkci jinak). Dřív si rádio,
Pusť teď, Denní mixy, blendy a filtr nových skládaly každý svou sadu
dotazů a každý znal jen část pravidel (rádio ne import, blend ne pauzy,
Pusť teď jediný "většinou přeskakované").

Pravidla, stejná všude:

Vždy ven (známé i nové):
- skladba "nelíbí se", interpret "nelíbí se",
- 2x po sobě přeskočená (appka 90 dní, import v kontextu algoritmu 180 dní).

Nové navíc ven (`novelty.filter_new`):
- už slyšená (i pod jiným id), interpret "míň takových",
- pauza "nabídnuto, nepuštěno" (app/home/repetition.py),
- karaoke, cover "in the style of", slowed / nightcore apod.

Známé jen slabší (`weight`), nic se nezakazuje:
- interpret "víc / míň takových" (feedback.fit_multiplier),
- většinou přeskakovaná (skip_heavy) ×0,3,
- známá 2x nabídnutá bez poslechu za 7 dní ×0,3 (jako Pusť teď).
Skládání bez vah (rádio, blend) bere `filter`: známé od interpreta
"míň takových" vynechá, jako dřív.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field
from datetime import timedelta

from sqlmodel import Session, select

from app.db import engine

SKIP_DAYS = 90
SKIP_HEAVY_WEIGHT = 0.3
TIRED_WEIGHT = 0.3  # jako Pusť teď
# Personal_mixes._JUNK + taste_bridge.JUNK_VERSION dohromady (dřív každý jinde).
_JUNK_TEXT = ("karaoke", "originally performed", "in the style of", "made famous by", "tribute to", "instrumental version")
_JUNK_VERSION = re.compile(r"(slowed|sped up|speed up|reverb|nightcore|8d audio|instrumental)", re.I)


def is_junk(title: str | None, artist: str | None = None) -> bool:
    """Karaoke / cover napodobenina / upravená verze -- jako nová skladba ne."""
    text = f"{title or ''} {artist or ''}".lower()
    return any(m in text for m in _JUNK_TEXT) or bool(_JUNK_VERSION.search(title or ""))


@dataclass
class Guard:
    banned_artists: set[str] = field(default_factory=set)
    bad_tracks: set[str] = field(default_factory=set)
    skipped: set[str] = field(default_factory=set)
    paused: set[str] = field(default_factory=set)
    tired: set[str] = field(default_factory=set)
    skip_heavy: set[str] = field(default_factory=set)
    feedback: dict[str, float] = field(default_factory=dict)  # interpret -> delta

    @property
    def muted_artists(self) -> set[str]:
        return {a for a, d in self.feedback.items() if d < 0}

    def allowed(self, recording_id: str, artist_id: str | None, *, new: bool = False) -> bool:
        if recording_id in self.bad_tracks or recording_id in self.skipped or artist_id in self.banned_artists:
            return False
        if new and (recording_id in self.paused or (artist_id is not None and self.feedback.get(artist_id, 0) < 0)):
            return False
        return True

    def weight(self, recording_id: str, artist_id: str | None) -> float:
        from app.home.feedback import fit_multiplier

        w = fit_multiplier(self.feedback[artist_id]) if artist_id in self.feedback else 1.0
        if recording_id in self.skip_heavy:
            w *= SKIP_HEAVY_WEIGHT
        if recording_id in self.tired:
            w *= TIRED_WEIGHT
        return w

    def filter(
        self, recording_ids: list[str], artist_of: dict[str, str | None], *, known: set[str] | None = None
    ) -> list[str]:
        """Pro skládání bez vah: tvrdá pravidla + bez interpretů "míň takových".
        S `known` se skladby mimo ni berou jako nové (pauza nabídek)."""
        muted = self.muted_artists
        return [
            r
            for r in recording_ids
            if self.allowed(r, artist_of.get(r), new=known is not None and r not in known)
            and artist_of.get(r) not in muted
        ]

    def merge(self, other: Guard) -> Guard:
        """Pro dva posluchače (blend): co nechce aspoň jeden z nich."""
        fb = dict(self.feedback)
        for a, d in other.feedback.items():
            fb[a] = min(fb.get(a, d), d)
        return Guard(
            banned_artists=self.banned_artists | other.banned_artists,
            bad_tracks=self.bad_tracks | other.bad_tracks,
            skipped=self.skipped | other.skipped,
            paused=self.paused | other.paused,
            tired=self.tired | other.tired,
            skip_heavy=self.skip_heavy | other.skip_heavy,
            feedback=fb,
        )


def skipped_ids(session: Session, user_id: str) -> set[str]:
    """2x po sobě přeskočené: appka (SkipStreak, 90 dní) + import (180 dní)."""
    from app.home import repetition
    from app.models import SkipStreak
    from app.utils import utcnow

    since = (utcnow() - timedelta(days=SKIP_DAYS)).replace(tzinfo=None)
    app_skips = set(
        session.exec(
            select(SkipStreak.recording_id).where(
                SkipStreak.user_id == user_id, SkipStreak.streak >= 2, SkipStreak.updated_at >= since
            )
        ).all()
    )
    return app_skips | repetition.imported_skips(user_id)


def load(user_id: str, session: Session | None = None) -> Guard:
    """Čte se pokaždé znovu (nelíbí se / míň takových platí hned); drahé části
    (import, nabídky, skip_heavy) mají vlastní mezipaměť."""
    from app.home import repetition, skip_heavy
    from app.home.feedback import deltas
    from app.library.dislikes import disliked_artist_ids, disliked_ids

    def _load(s: Session) -> Guard:
        paused, tired = repetition.ignored_offers(user_id)
        return Guard(
            banned_artists=disliked_artist_ids(s, user_id),
            bad_tracks=disliked_ids(s, user_id),
            skipped=skipped_ids(s, user_id),
            paused=paused,
            tired=tired,
            skip_heavy=skip_heavy.for_user(user_id),
            feedback=deltas(user_id),
        )

    if session is not None:
        return _load(session)
    with Session(engine) as s:
        return _load(s)
