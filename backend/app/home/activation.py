"""Vkus z celé historie poslechů: tři profily a aktivace skladeb.

Nahrazuje řez "posledních 365 dní" (útes: poslech z loňska vážil nulu, z
letoška plně). Vychází z rešerše (opentify-notes/recommendation-research):

- **dlouhý profil** – celá historie, mocninný útlum ACT-R
  `w = max(Δdní, 0.5) ** -0.5` (Reiter-Haas a kol., RecSys 2021): staré
  oblíbené nezmizí, ale nepřebijí současnost;
- **střední** – poločas ~100 dní (co posloucháš posledního půl roku);
- **krátký** – poločas ~10 dní (co posloucháš teď).

Každý poslech váží stejně bez ohledu na zdroj (Spotify, YouTube Music,
Apple, appka – feedback_equal_listen_weight); jediný rozdíl je, kolik se z
něj opravdu slyšelo (pod polovinu / 4 min = 0,5). Za den se u jedné skladby
počítají nejvýš 3 poslechy, ať jeden den na opakování nepřebije roky.

Každý profil se převede na podíly interpretů, aby šly míchat
(`ARTIST_BLEND`). Rešerše radila `ln(1 + Σw)`; offline test na skutečné
historii vyšel s přímými podíly líp, tak zůstaly ty.
"""

from __future__ import annotations

import math
import re
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import datetime, timezone

from sqlmodel import Session, select

from app.db import engine
from app.models import Artist, Listen, Recording
from app.utils import utcnow

# Nastaveno offline testem na 119 tis. poslechů vlastníka (app/tools/taste_replay,
# 5. 10. 2026): poločasy 14 / 60 dní předpovídají příští týden nejlíp.
SHORT_HALF_LIFE = 14.0
MEDIUM_HALF_LIFE = 60.0
LONG_DECAY = 0.5
# Mix profilů pro výběr interpretů (test: +25 % proti řezu 365 dní).
ARTIST_BLEND = {"long": 0.5, "medium": 0.3, "short": 0.2}
MAX_PER_DAY = 3
# "Bývalá láska" (Návrat do minulosti): aspoň tolik poslechů v jednom
# 60denním okně, pak ticho.
PEAK_WINDOW_DAYS = 60
PEAK_MIN = 4


def _aware(value: datetime) -> datetime:
    return value if value.tzinfo else value.replace(tzinfo=timezone.utc)


def track_key(artist_name: str, title: str) -> str:
    """Interpret + název bez verzí a diakritiky -- "už slyšené" i když import
    a katalog mají tutéž skladbu pod jiným id ("(Remastered 2009)", feat.)."""
    from app.download_match import core_title, fold, tokens

    artist = re.split(r"\s*(?:,|&| feat\.? | ft\.? | x | and | a )\s*", fold(artist_name or ""), maxsplit=1)[0].strip()
    return f"{artist}|{' '.join(tokens(core_title(title or '')))}"


@dataclass
class Activation:
    now: datetime
    # recording -> aktivace (součet vah) v jednotlivých profilech
    short: Counter = field(default_factory=Counter)
    medium: Counter = field(default_factory=Counter)
    long: Counter = field(default_factory=Counter)
    total: Counter = field(default_factory=Counter)  # počet poslechů
    first: dict[str, datetime] = field(default_factory=dict)
    last: dict[str, datetime] = field(default_factory=dict)
    peak: dict[str, int] = field(default_factory=dict)  # nejvíc poslechů v 60denním okně
    peak_at: dict[str, datetime] = field(default_factory=dict)
    artist_of: dict[str, str] = field(default_factory=dict)
    heard_keys: set[str] = field(default_factory=set)

    def artist_scores(self, profile: str) -> Counter:
        """Interpret -> podíl v profilu (součet 1). Přímé podíly, ne `ln` --
        offline test vyšel s logaritmem hůř (zplošťuje rozdíly)."""
        acc: Counter = Counter()
        for rid, w in getattr(self, profile).items():
            artist = self.artist_of.get(rid)
            if artist:
                acc[artist] += w
        total = sum(acc.values()) or 1.0
        return Counter({a: v / total for a, v in acc.items() if v > 0})

    def blend(self, weights: dict[str, float]) -> Counter:
        """Interpreti podle smíchaných profilů, např. {"medium": .6, "short": .4}."""
        out: Counter = Counter()
        for profile, w in weights.items():
            for artist, share in self.artist_scores(profile).items():
                out[artist] += w * share
        return out

    def former_loves(self, quiet_days: int = 120, min_years_for_binges: float = 1.0) -> list[str]:
        """Skladby, které byly oblíbené (vrchol ≥ PEAK_MIN v okně) a teď jsou
        potichu. Ohrané (skoro všechny poslechy v jedné vlně) až po roce.
        Seřazené podle `peak × (1 − teď/vrchol)`."""
        out: list[tuple[float, str]] = []
        for rid, peak in self.peak.items():
            if peak < PEAK_MIN:
                continue
            last = self.last.get(rid)
            if last is None or (self.now - last).days < quiet_days:
                continue
            binge = self.total[rid] and peak / self.total[rid] >= 0.7
            if binge and (self.now - last).days < 365 * min_years_for_binges:
                continue
            short_now = self.short.get(rid, 0.0)
            out.append((peak * (1 - min(1.0, short_now / peak)), rid))
        out.sort(reverse=True)
        return [rid for _s, rid in out]


def compute(user_id: str, now: datetime | None = None, before: datetime | None = None) -> Activation:
    """`before`: jen poslechy před tímhle okamžikem (offline test: jak by
    model vypadal k danému dni)."""
    now = _aware(now or utcnow())
    act = Activation(now=now)
    ln2 = math.log(2)
    with Session(engine) as session:
        query = select(Listen.recording_id, Listen.played_at, Listen.duration_played_ms).where(Listen.user_id == user_id)
        if before is not None:
            query = query.where(Listen.played_at < before.replace(tzinfo=None))
        rows = session.exec(query).all()
        durations: dict[str, int | None] = {}
        rids = {r for r, _p, _m in rows}
        ids = list(rids)
        names: dict[str, str] = {}
        for i in range(0, len(ids), 500):
            for rid, title, artist_id, dur in session.exec(
                select(Recording.id, Recording.title, Recording.artist_id, Recording.duration_ms).where(
                    Recording.id.in_(ids[i : i + 500])  # type: ignore[attr-defined]
                )
            ).all():
                durations[rid] = dur
                if artist_id:
                    act.artist_of[rid] = artist_id
                names[rid] = title or ""
        artist_ids = list(set(act.artist_of.values()))
        artist_name: dict[str, str] = {}
        for i in range(0, len(artist_ids), 500):
            for aid, name in session.exec(
                select(Artist.id, Artist.name).where(Artist.id.in_(artist_ids[i : i + 500]))  # type: ignore[attr-defined]
            ).all():
                artist_name[aid] = name
    for rid, title in names.items():
        act.heard_keys.add(track_key(artist_name.get(act.artist_of.get(rid, ""), ""), title))

    per_day: Counter = Counter()
    times: dict[str, list[datetime]] = defaultdict(list)
    for rid, played_at, ms in sorted(rows, key=lambda r: r[1]):
        played = _aware(played_at)
        day = (rid, played.date())
        per_day[day] += 1
        if per_day[day] > MAX_PER_DAY:
            continue
        dur = durations.get(rid)
        heard = 1.0
        if ms is not None and dur and ms < min(dur / 2, 240_000):
            heard = 0.5  # 30 s – polovina: slyšel, ale ne celou
        age = max((now - played).total_seconds() / 86400, 0.5)
        act.short[rid] += heard * math.exp(-ln2 * age / SHORT_HALF_LIFE)
        act.medium[rid] += heard * math.exp(-ln2 * age / MEDIUM_HALF_LIFE)
        act.long[rid] += heard * age ** -LONG_DECAY
        act.total[rid] += 1
        act.first.setdefault(rid, played)
        act.last[rid] = played
        times[rid].append(played)
    # Vrchol: nejvíc poslechů v klouzavém 60denním okně.
    for rid, ts in times.items():
        best, best_at, j = 0, ts[0], 0
        for i, t in enumerate(ts):
            while (t - ts[j]).days > PEAK_WINDOW_DAYS:
                j += 1
            if i - j + 1 > best:
                best, best_at = i - j + 1, t
        act.peak[rid] = best
        act.peak_at[rid] = best_at
    return act
