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
from app.models import Artist, Listen, PlayEvent, Recording
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


# Vkus ve vrstvách (opentify-notes/skladani-hudby-navrh-2026-10-07.md):
# všechno slyšené se projeví hned, ale natrvalo jen to, k čemu se člověk
# sám VRACÍ (vlastní volba: hledání, album, interpret, knihovna) nebo co si
# výslovně vybral (srdíčko, knihovna, playlist, "víc takových" -> platí
# hned). Váhy z auditu 7. 10. na 8 807 nových interpretech vlastníka: kolik
# jich vydrželo (poslech aspoň ve 3 dnech v dalším roce) podle počtu dní a
# rozpětí v prvních 30 dnech -- 1 den 10 %, 3 dny přes 2 týdny 38 %, 5+ dní
# přes 2 týdny 76 % (= plná váha). Poslech, který pustil algoritmus (Pusť teď,
# mix, rádio, žebříček), se do návratů počítá jen třetinou dne. Import =
# vlastní volba (stejná váha, feedback_equal_listen_weight).
YOUNG_DAYS = 30  # mladý profil = méně různých dnů poslechu (audit: 300 poslechů jsou u někoho 4 dny)
ALGO_DAY = 1 / 3
CONFIRMED_AT = 0.5  # od téhle váhy je interpret "potvrzený" (Celá alba, osobní část)


def persistence_weight(days: float, span_days: float) -> float:
    """Váha interpreta pro trvalý vkus (0,13-1) podle návratů: `days` různých
    dnů (algoritmus = třetina dne), `span_days` první-poslední poslech."""
    if days < 2:
        return 0.13
    if days < 3:
        return 0.2 if span_days < 7 else 0.25
    if days < 4:
        return 0.35 if span_days < 7 else (0.4 if span_days < 14 else 0.5)
    if days < 5:
        return 0.35 if span_days < 7 else 0.53
    # 5+ dní: týdenní nárazové poslouchání vydrží málokdy (15 %), přes 2 týdny ano.
    return 0.2 if span_days < 7 else (0.75 if span_days < 14 else 1.0)


def youngness(listening_days: int) -> float:
    """1 = úplně nový profil, 0 = zaběhlý (YOUNG_DAYS a víc dnů poslechu)."""
    return max(0.0, 1.0 - listening_days / YOUNG_DAYS)


def tentative_factors(
    artist_days: dict[str, tuple[float, float]], confirmed: set[str], listening_days: int
) -> dict[str, float]:
    """Interpret -> násobek jeho vlivu na trvalý vkus (chybí = 1). U mladého
    profilu nepotvrzený interpret táhne jen podle váhy návratů; s přibývajícími
    dny poslechu se rozdíl plynule ztrácí. `confirmed` = výslovné volby."""
    young = youngness(listening_days)
    if young <= 0:
        return {}
    out: dict[str, float] = {}
    for a, (days, span) in artist_days.items():
        if a in confirmed:
            continue
        w = persistence_weight(days, span)
        if w < 1.0:
            out[a] = 1 - (1 - w) * young
    return out


def artist_day_stats(rows) -> dict[str, tuple[float, float]]:
    """(čas, interpret[, z algoritmu]) -> interpret -> (dní, rozpětí v dnech).
    Den, kdy interpreta pustil jen algoritmus, se počítá třetinou."""
    own: dict[str, set] = defaultdict(set)
    algo: dict[str, set] = defaultdict(set)
    first: dict[str, datetime] = {}
    last: dict[str, datetime] = {}
    for row in rows:
        t, a = row[0], row[1]
        is_algo = bool(row[2]) if len(row) > 2 else False
        if not a:
            continue
        (algo if is_algo else own)[a].add(t.date())
        if a not in first or t < first[a]:
            first[a] = t
        if a not in last or t > last[a]:
            last[a] = t
    return {
        a: (len(own[a]) + ALGO_DAY * len(algo[a] - own[a]), (last[a] - first[a]).total_seconds() / 86400)
        for a in first
    }


# Odkud poslech je: fronty, které skládá algoritmus nebo cizí výběr (mixy,
# rádio, Pusť teď, žebříčky, žánrové a redakční playlisty). Stejné druhy
# jako PlayEvent.algorithmic (app/connect_listens.py) + žebříčky.
# JEDNA definice pro přehrání (PlayEvent, app/connect_listens.py) i poslech
# (audit 7. 10. po změnách, chyba 10).
ALGO_KINDS = ("PERSONAL_MIX", "GENERATED_RECOMMENDATION", "RADIO", "CHART", "GENRE", "EDITORIAL")
_ALGO_KINDS = ALGO_KINDS
ALGO_MATCH_S = 20 * 60
_ALGO_PREFIXES = ("Pusť teď", "Rádio · ")
TASTE_SOURCES = ("spotify-history", "applemusic-history", "ytmusic-history")


def algorithmic_labels(session: Session, user_id: str) -> set[str]:
    from app.models import GLOBAL_PLAYLIST_OWNER, Playlist

    return {
        t for t in session.exec(
            select(Playlist.title).where(
                Playlist.owner_user_id.in_([user_id, GLOBAL_PLAYLIST_OWNER]),  # type: ignore[attr-defined]
                Playlist.kind.in_(_ALGO_KINDS),  # type: ignore[attr-defined]
            )
        ).all() if t
    }


def is_algorithmic(source: str | None, labels: set[str]) -> bool:
    """Poslech z appky: pustil ho algoritmus? (Import řeší `import_algorithmic`.)"""
    if not source or source in TASTE_SOURCES:
        return False
    return source in labels or source.startswith(_ALGO_PREFIXES)


# Import (Spotify / Apple): algoritmus není nikdy vlastní volba (uživatel
# 7. 10.). Vlastní volba = vybral skladbu (Spotify `reason_start` clickrow,
# ukládá se od 7. 10. do `Listen.context`), skladba z jeho sbírky (srdíčka,
# knihovna, vlastní playlisty), nebo aspoň 3 skladby stejného alba /
# interpreta za sebou (pustil si album nebo interpreta -- algoritmus tak
# nehraje). Zbytek (osamocené cizí skladby: Objevy týdne, rádio, autoplay,
# ale bez `reason_start` i jednotlivě vyhledané) se počítá jako algoritmus.
# Audit 7. 10.: u vlastníka takhle ~50 % Spotify historie vlastní volba.
OWN_REASONS = ("clickrow",)
RUN_MIN = 3
RUN_GAP_S = 15 * 60


def import_algorithmic(rows: list[tuple], collection: set[str]) -> set[int]:
    """`rows` = (čas, recording, album, interpret, context) seřazené podle
    času; vrací indexy poslechů, které pustil algoritmus."""
    n = len(rows)

    def runs(idx: int) -> list[int]:
        out = [1] * n
        i = 0
        while i < n:
            j = i
            key = rows[i][idx]
            while (
                key and j + 1 < n and rows[j + 1][idx] == key
                and (rows[j + 1][0] - rows[j][0]).total_seconds() < RUN_GAP_S
            ):
                j += 1
            for k in range(i, j + 1):
                out[k] = j - i + 1
            i = j + 1
        return out

    by_album, by_artist = runs(2), runs(3)
    algo: set[int] = set()
    for k, (_t, rid, _rel, _art, context) in enumerate(rows):
        reason = (context or "").split(":")[-1] if (context or "").startswith("spotify:") else None
        if reason in OWN_REASONS or rid in collection or by_album[k] >= RUN_MIN or by_artist[k] >= RUN_MIN:
            continue
        algo.add(k)
    return algo


def collection_tracks(session: Session, user_id: str) -> set[str]:
    """Sbírka profilu: srdíčka, knihovna a vlastní playlisty."""
    from app.home.play_now import _chosen_tracks
    from app.models import Playlist, PlaylistItem, PlaylistKind

    out = set(_chosen_tracks(session, user_id, 100_000))
    own = [p for p in session.exec(
        select(Playlist.id).where(Playlist.owner_user_id == user_id, Playlist.kind == PlaylistKind.USER)
    ).all()]
    if own:
        out |= set(session.exec(select(PlaylistItem.recording_id).where(PlaylistItem.playlist_id.in_(own))).all())  # type: ignore[attr-defined]
    return out


def taste_exclusions(user_id: str) -> tuple[set[str], set[str]]:
    """(skladby, playlisty) vyjmuté ze vkusu volbou "Nepočítat do vkusu" v
    menu ⋯ (puštěno pro někoho, na usínání...). Poslech takové skladby /
    z takového playlistu se do vkusu nepočítá; Wrapped a historie ano."""
    from app.models import HomeSnapshot

    with Session(engine) as session:
        row = session.get(HomeSnapshot, f"taste_excluded:{user_id}")
    payload = (row.payload or {}) if row else {}
    return set(payload.get("recordings") or []), set(payload.get("playlists") or [])


def excluded_sources(user_id: str) -> set[str]:
    """Zdroje importu, které si profil vypnul ze vkusu (Profil › Hudba)."""
    from app.models import HomeSnapshot

    with Session(engine) as session:
        row = session.get(HomeSnapshot, f"taste_sources:{user_id}")
    return set((row.payload or {}).get("excluded") or []) if row else set()


# Vkus "připravený" na mixy žánrů a stylů podle nejbližší hudby (i žánr,
# který profil ještě neobjevil): zaběhlý profil, nebo dost potvrzených
# interpretů.
READY_CONFIRMED = 12


@dataclass
class TasteState:
    listening_days: int
    young: float  # 1 = úplně nový, 0 = zaběhlý
    confirmed: set[str]  # výslovné volby + interpreti s váhou návratů >= CONFIRMED_AT
    explicit: set[str]  # srdíčko, knihovna, oblíbený interpret, "víc takových"
    day_stats: dict[str, tuple[float, float]]

    @property
    def ready(self) -> bool:
        return self.young <= 0 or len(self.confirmed) >= READY_CONFIRMED

    def factors(self) -> dict[str, float]:
        return tentative_factors(self.day_stats, self.explicit, self.listening_days)


def explicit_artists(user_id: str) -> set[str]:
    """JEDNA definice výslovné volby pro všechny plochy (audit 7. 10. po
    změnách, chyba 4 -- dřív tři různé): interpreti srdíček, knihovny a
    VLASTNÍCH playlistů (sdílené ne -- skladby tam přidal i někdo jiný),
    sledovaní interpreti a "víc takových". Bez limitů."""
    from app.home.feedback import deltas
    from app.models import FavoriteArtist

    with Session(engine) as session:
        tracks = collection_tracks(session, user_id)
        favorites = set(session.exec(select(FavoriteArtist.artist_id).where(FavoriteArtist.user_id == user_id)).all())
        ids = list(tracks)
        artists: set[str] = set()
        for i in range(0, len(ids), 500):
            artists |= {
                a for a in session.exec(
                    select(Recording.artist_id).where(Recording.id.in_(ids[i : i + 500]))  # type: ignore[attr-defined]
                ).all() if a
            }
    return artists | favorites | {a for a, d in deltas(user_id).items() if d > 0}


def cached(user_id: str) -> "Activation":
    """`compute` přes sdílenou mezipaměť (app/home/taste_cache.py, 15 min,
    zahodí se při výslovné volbě). Volající do výsledku nesmí zapisovat."""
    from app.home import taste_cache

    return taste_cache.get("activation", user_id, lambda: compute(user_id))


def taste_state(user_id: str, act: "Activation | None" = None) -> TasteState:
    act = act or cached(user_id)
    stats = act.artist_days()
    explicit = explicit_artists(user_id)
    confirmed = explicit | {a for a, (d, span) in stats.items() if persistence_weight(d, span) >= CONFIRMED_AT}
    days = act.listening_days()
    return TasteState(days, youngness(days), confirmed, explicit, stats)


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
    title_of: dict[str, str] = field(default_factory=dict)  # recording -> název
    heard_keys: set[str] = field(default_factory=set)
    # (čas, skladba) všech započtených poslechů, chronologicky -- co se
    # poslouchá spolu (Pusť teď / nekonečné hraní).
    timeline: list[tuple[datetime, str]] = field(default_factory=list)
    # Pustil to algoritmus? (paralelně s `timeline`)
    timeline_algo: list[bool] = field(default_factory=list)

    def artist_days(self) -> dict[str, tuple[float, float]]:
        """Interpret -> (dní návratů, algoritmus = třetina dne; rozpětí v dnech)."""
        algo = self.timeline_algo or [False] * len(self.timeline)
        return artist_day_stats((t, self.artist_of.get(r), al) for (t, r), al in zip(self.timeline, algo))

    def listening_days(self) -> int:
        return len({t.date() for t, _r in self.timeline})

    def co_listened_artists(self, seed_artists: set[str], window_min: int = 60) -> Counter:
        """Interpreti, které profil pouští ve stejných chvílích jako semínka
        (do `window_min` minut od poslechu semínka). Podobnost z vlastní
        historie, ne z cizích dat."""
        out: Counter = Counter()
        times = [(t, self.artist_of.get(r)) for t, r in self.timeline]
        j = 0
        seed_idx = [i for i, (_t, a) in enumerate(times) if a in seed_artists]
        for i in seed_idx:
            t = times[i][0]
            j = i
            while j > 0 and (t - times[j - 1][0]).total_seconds() <= window_min * 60:
                j -= 1
            k = i
            while k + 1 < len(times) and (times[k + 1][0] - t).total_seconds() <= window_min * 60:
                k += 1
            for _t, a in times[j : k + 1]:
                if a and a not in seed_artists:
                    out[a] += 1
        return out

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
        query = select(
            Listen.recording_id, Listen.played_at, Listen.duration_played_ms, Listen.source, Listen.context
        ).where(Listen.user_id == user_id)
        if before is not None:
            query = query.where(Listen.played_at < before.replace(tzinfo=None))
        excluded = excluded_sources(user_id)
        ex_recs, ex_playlists = taste_exclusions(user_id)
        ex_paths = {f"/playlists/{p}" for p in ex_playlists}
        labels = algorithmic_labels(session, user_id)
        algo_of: dict[tuple[str, datetime], bool] = {}
        rows = []
        imported = []
        for rid, played_at, ms, source, context in session.exec(query).all():
            if source in excluded or rid in ex_recs or (context or "").split("?")[0] in ex_paths:
                continue  # zdroj / skladba / playlist vyjmuté ze vkusu (Wrapped a roky je počítají dál)
            rows.append((rid, played_at, ms))
            if source in TASTE_SOURCES:
                imported.append((played_at, rid, context))
            elif is_algorithmic(source, labels):
                algo_of[(rid, played_at)] = True
        # Poslech z várky Pusť teď / nekonečného hraní = algoritmus, i když
        # nese název původní fronty (klient doplňuje várky pod názvem alba --
        # audit 7. 10. po změnách, chyba 1): přehrání (PlayEvent), které pustil
        # algoritmus nebo patří do várky, do 20 minut od poslechu.
        algo_plays: dict[str, list[datetime]] = defaultdict(list)
        for rid, ended in session.exec(
            select(PlayEvent.recording_id, PlayEvent.ended_at).where(
                PlayEvent.user_id == user_id,
                PlayEvent.origin == "connect",
                (PlayEvent.algorithmic == True) | (PlayEvent.rec_batch_id.is_not(None)),  # type: ignore[union-attr] # noqa: E712
            )
        ).all():
            algo_plays[rid].append(ended)
        if algo_plays:
            for rid, played_at, _ms in rows:
                for ended in algo_plays.get(rid, ()):
                    if abs((ended - played_at).total_seconds()) <= ALGO_MATCH_S:
                        algo_of[(rid, played_at)] = True
                        break
        if imported:
            imported.sort()
            meta: dict[str, tuple[str | None, str | None]] = {}
            imp_ids = list({r for _t, r, _c in imported})
            for i in range(0, len(imp_ids), 500):
                for r, rel, art in session.exec(
                    select(Recording.id, Recording.release_id, Recording.artist_id).where(
                        Recording.id.in_(imp_ids[i : i + 500])  # type: ignore[attr-defined]
                    )
                ).all():
                    meta[r] = (rel, art)
            full = [(t, r, *meta.get(r, (None, None)), c) for t, r, c in imported]
            for k in import_algorithmic(full, collection_tracks(session, user_id)):
                algo_of[(full[k][1], full[k][0])] = True
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
        act.title_of[rid] = title
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
        is_algo = algo_of.get((rid, played_at), False)
        act.short[rid] += heard * math.exp(-ln2 * age / SHORT_HALF_LIFE)
        act.medium[rid] += heard * math.exp(-ln2 * age / MEDIUM_HALF_LIFE)
        # Dlouhý (trvalý) profil: co pustil algoritmus, jen třetinou -- i u
        # zaběhlého profilu, ať si Pusť teď nepotvrzuje samo sebe (uživatel
        # 7. 10., audit bod 9). Krátký a střední (co posloucháš teď) plně.
        act.long[rid] += heard * (ALGO_DAY if is_algo else 1.0) * age ** -LONG_DECAY
        act.total[rid] += 1
        act.first.setdefault(rid, played)
        act.last[rid] = played
        times[rid].append(played)
        act.timeline.append((played, rid))
        act.timeline_algo.append(algo_of.get((rid, played_at), False))
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
