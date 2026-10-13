"""Mapa scén profilu (F3, 13. 10.): celá historie rozdělená do skupin
interpretů, které se poslouchají spolu a znějí podobně ("bluegrass",
"česká písničkářská", "soft rock 70. let"...). Dřív doporučování vidělo jen
nejsilnějších 60 interpretů posledních měsíců v nejvýš 6 skupinách -- deset
let různorodé historie se v mixech skoro neukázalo.

- Jádro: interpreti, ke kterým se profil vrátil aspoň ve 2 dnech.
- Podobnost: společné relace (poslechy s mezerou < 30 min; puštěné
  algoritmem po třetinách) × styl podle štítků Last.fm (záloha: žánry
  Deezeru). Pro každého jen nejbližších `K` sousedů.
- Skupiny: Louvain (bez knihoven); malé skupiny se přidají k nejbližší.
- Ocas (interpret z jediného dne) se přiřadí ke scéně, se kterou se
  nejčastěji poslouchal.
- Přepočet jednou týdně (`build`, plánovač každou hodinu kontroluje týden).

Kdo scény používá: Denní mixy (3 střídající se ze spících scén), Pusť teď
(1–2 skladby ze spící scény), Objevy týdne (semínka z mnoha scén).
"""

from __future__ import annotations

import asyncio
import json
import logging
import math
import random
from collections import Counter, defaultdict
from dataclasses import dataclass, field
from datetime import date

from sqlmodel import Session

from app.db import engine

logger = logging.getLogger(__name__)

SESSION_GAP_S = 30 * 60
NEIGHBOURS = 15
RESOLUTION = 8.0
VERSION = 2  # 13. 10.: dělení scén podle stylu  # vyšší = víc menších scén (5 dalo 41 scén, cíl 60–80)
MIN_SCENE = 4  # menší skupina se přidá k nejbližší scéně
DORMANT_RATIO = 0.5  # podíl "teď" proti "dlouhodobě" pod tím = scéna spí
SHOWN_COOLDOWN_DAYS = 10


@dataclass
class Scene:
    id: str  # nejsilnější interpret scény (stálý mezi přepočty)
    artists: list[str]  # jádro, nejsilnější první
    tail: list[str] = field(default_factory=list)
    label: str = ""  # nejsilnější štítky
    weight: float = 0.0  # podíl na dlouhodobém vkusu
    now: float = 0.0  # podíl na posledních týdnech (střední profil)
    peak_year: int | None = None
    last_year: int | None = None

    @property
    def dormant(self) -> bool:
        return self.weight > 0 and self.now < DORMANT_RATIO * self.weight

    def to_json(self) -> dict:
        return {
            "id": self.id, "artists": self.artists, "tail": self.tail, "label": self.label,
            "weight": self.weight, "now": self.now, "peak": self.peak_year, "last": self.last_year,
        }

    @classmethod
    def from_json(cls, d: dict) -> "Scene":
        return cls(
            id=d["id"], artists=list(d.get("artists") or []), tail=list(d.get("tail") or []),
            label=d.get("label") or "", weight=float(d.get("weight") or 0), now=float(d.get("now") or 0),
            peak_year=d.get("peak"), last_year=d.get("last"),
        )


@dataclass
class SceneMap:
    scenes: list[Scene] = field(default_factory=list)

    def scene_of(self) -> dict[str, str]:
        out = {}
        for s in self.scenes:
            for a in s.tail:
                out[a] = s.id
            for a in s.artists:
                out[a] = s.id
        return out

    def by_id(self) -> dict[str, Scene]:
        return {s.id: s for s in self.scenes}


# --------------------------------------------------------------- úložiště


def _key(user_id: str) -> str:
    return f"scenes:{user_id}"


def _shown_key(user_id: str) -> str:
    return f"scenes-shown:{user_id}"


def load(user_id: str) -> SceneMap:
    from app.models import HomeSnapshot

    with Session(engine) as session:
        snap = session.get(HomeSnapshot, _key(user_id))
    raw = (snap.payload or {}).get("scenes") if snap else None
    return SceneMap([Scene.from_json(d) for d in raw or []])


def _save(user_id: str, smap: SceneMap, stamp: str) -> None:
    from app.models import HomeSnapshot
    from app.utils import utcnow

    with Session(engine) as session:
        row = session.get(HomeSnapshot, _key(user_id)) or HomeSnapshot(key=_key(user_id))
        row.payload = {"stamp": stamp, "scenes": [s.to_json() for s in smap.scenes]}
        row.generated_at = utcnow()
        session.add(row)
        session.commit()


def _stamp(user_id: str) -> str | None:
    from app.models import HomeSnapshot

    with Session(engine) as session:
        snap = session.get(HomeSnapshot, _key(user_id))
    return (snap.payload or {}).get("stamp") if snap else None


def shown_days(user_id: str) -> dict[str, str]:
    """Scéna -> den, kdy byla naposledy v Denních mixech."""
    from app.models import HomeSnapshot

    with Session(engine) as session:
        snap = session.get(HomeSnapshot, _shown_key(user_id))
    return dict((snap.payload or {}).get("days") or {}) if snap else {}


def mark_shown(user_id: str, scene_ids: list[str], day: str) -> None:
    from app.models import HomeSnapshot
    from app.utils import utcnow

    days = shown_days(user_id)
    for sid in scene_ids:
        days[sid] = day
    with Session(engine) as session:
        row = session.get(HomeSnapshot, _shown_key(user_id)) or HomeSnapshot(key=_shown_key(user_id))
        row.payload = {"days": days}
        row.generated_at = utcnow()
        session.add(row)
        session.commit()


# --------------------------------------------------------------- výběr


def pick_dormant(
    smap: SceneMap, n: int, rng: random.Random, *, today: str | None = None,
    shown: dict[str, str] | None = None, exclude_artists: set[str] | None = None,
) -> list[Scene]:
    """`n` spících scén, losovaných podle toho, jak moc byly oblíbené; nedávno
    ukázané (Denní mixy) mají pauzu. Scény, jejichž hlavní interpreti už jsou
    jinde (stálé mixy), se přeskočí."""
    shown = shown or {}
    exclude_artists = exclude_artists or set()
    keyed = []
    for s in smap.scenes:
        if not s.dormant or len(s.artists) < MIN_SCENE:
            continue
        if exclude_artists and len(set(s.artists[:5]) & exclude_artists) >= 2:
            continue
        w = s.weight ** 0.7  # i menší scény mají šanci
        if today and s.id in shown:
            try:
                age = (date.fromisoformat(today) - date.fromisoformat(shown[s.id])).days
            except ValueError:
                age = SHOWN_COOLDOWN_DAYS
            if age < SHOWN_COOLDOWN_DAYS:
                w *= 0.02 + 0.98 * (age / SHOWN_COOLDOWN_DAYS) ** 2
        if w > 0:
            keyed.append((rng.random() ** (1.0 / w), s))
    keyed.sort(key=lambda x: x[0], reverse=True)
    return [s for _k, s in keyed[:n]]


# --------------------------------------------------------------- výpočet


async def build() -> int:
    """Plánovač (každou hodinu): přepočet jednou týdně pro aktuální profil."""
    from app.home import generators as g
    from app.home.personal_mixes import _week_key

    user_id = g.home_user()
    week = f"{_week_key()}:v{VERSION}"  # nová verze výpočtu = přepočet hned
    if await asyncio.to_thread(_stamp, user_id) == week:
        return len(await asyncio.to_thread(lambda: load(user_id).scenes))
    smap = await compute(user_id)
    if smap.scenes:
        await asyncio.to_thread(_save, user_id, smap, week)
    logger.info("scény %s: %d", user_id[:8], len(smap.scenes))
    return len(smap.scenes)


async def compute(user_id: str, resolution: float = RESOLUTION) -> SceneMap:
    from app.home import activation as av

    act = await asyncio.to_thread(av.cached, user_id)
    days = act.artist_days()
    long_art = act.artist_scores("long")
    med_art = act.artist_scores("medium")
    names, genres = await asyncio.to_thread(_artist_meta, list({a for a in days if a} | set(long_art)))
    merge = _feat_merges(names)

    def canon(a: str | None) -> str | None:
        return merge.get(a, a) if a else a

    # Relace (puštěné algoritmem po třetinách).
    sessions: list[dict[str, float]] = []
    cur: dict[str, float] = {}
    last = None
    algo = act.timeline_algo or [False] * len(act.timeline)
    for (t, rid), al in zip(act.timeline, algo):
        a = canon(act.artist_of.get(rid))
        if not a:
            continue
        if last is not None and (t - last).total_seconds() > SESSION_GAP_S:
            if cur:
                sessions.append(cur)
            cur = {}
        cur[a] = max(cur.get(a, 0.0), 1 / 3 if al else 1.0)
        last = t
    if cur:
        sessions.append(cur)
    core_days: Counter = Counter()
    for a, (d, _span) in days.items():
        if a:
            core_days[canon(a)] += d
    core = {a for a, d in core_days.items() if d >= 2}
    if len(core) < 2 * MIN_SCENE:
        return SceneMap()
    tags = await _tag_vectors(core, names)
    adj = _graph(sessions, core, tags, genres, long_art)
    node_of = _louvain(adj, resolution)
    groups: dict[str, set[str]] = defaultdict(set)
    for a, c in node_of.items():
        groups[c].add(a)
    groups = _merge_small(groups, adj)
    _debug_stage("louvain+merge", groups, names)
    groups = _split_by_style(groups, tags, long_art)
    _debug_stage("split", groups, names)
    groups = _purify(groups, tags, long_art)
    # Vyhnanci mohli skončit ve scéně s pestrým stylem -- ještě jednou rozdělit.
    groups = _split_by_style(groups, tags, long_art)
    _debug_stage("purify+split", groups, names)
    scene_of = {a: c for c, ms in groups.items() for a in ms}
    # Ocas: interpret z jediného dne -> scéna, se kterou se nejčastěji poslouchal.
    votes: dict[str, Counter] = defaultdict(Counter)
    for s in sessions:
        sc = Counter(scene_of[a] for a in s if a in scene_of)
        if sc:
            for a in s:
                if a not in scene_of:
                    for c, n in sc.items():
                        votes[a][c] += n
    tails: dict[str, list[str]] = defaultdict(list)
    for a, v in votes.items():
        tails[v.most_common(1)[0][0]].append(a)
    years = _years(act, scene_of, canon)
    total_long = sum(long_art.get(a, 0.0) for a in scene_of) or 1.0
    total_med = sum(med_art.get(a, 0.0) for a in scene_of) or 1.0
    out = []
    for c, members in groups.items():
        ordered = sorted(members, key=lambda a: -long_art.get(a, 0.0))
        label_tags: Counter = Counter()
        from app.home.lastfm_taste import _BROAD

        for a in members:
            for t, v in (tags.get(a) or {}).items():
                if t not in _BROAD:
                    label_tags[t] += v * long_art.get(a, 0.0)
        yc = years.get(c) or Counter()
        peak = max(yc, key=yc.get) if yc else None
        last_year = max((y for y, n in yc.items() if n >= 0.1 * yc[peak]), default=None) if peak else None
        out.append(Scene(
            id=ordered[0],
            artists=ordered,
            tail=sorted(tails.get(c, []), key=lambda a: -long_art.get(a, 0.0)),
            label=", ".join(t for t, _ in label_tags.most_common(2)),
            weight=sum(long_art.get(a, 0.0) for a in members) / total_long,
            now=sum(med_art.get(a, 0.0) for a in members) / total_med,
            peak_year=peak,
            last_year=last_year,
        ))
    out.sort(key=lambda s: -s.weight)
    return SceneMap(out)


def _artist_meta(ids: list[str]) -> tuple[dict[str, str], dict[str, dict[str, float]]]:
    from app.models import Artist

    names, genres = {}, {}
    with Session(engine) as session:
        for aid in ids:
            if not aid:
                continue
            artist = session.get(Artist, aid)
            if artist is None:
                continue
            names[aid] = artist.name
            shares = (((artist.external_refs or {}).get("dzGenres") or {}).get("shares")) or {}
            total = sum(shares.values()) or 0
            if total:
                genres[aid] = {g: v / total for g, v in shares.items()}
    return names, genres


def _feat_merges(names: dict[str, str]) -> dict[str, str]:
    """"Passenger feat. Josh Pyke" -> Passenger (dřív samostatná mini scéna)."""
    from app.home.lastfm_taste import lastfm_name

    by_name = {n.casefold(): a for a, n in names.items()}
    out = {}
    for a, n in names.items():
        main = lastfm_name(n)
        if main and main.casefold() != n.casefold():
            target = by_name.get(main.casefold())
            if target and target != a:
                out[a] = target
    return out


async def _tag_vectors(core: set[str], names: dict[str, str]) -> dict[str, dict[str, float]]:
    from app.catalog.lastfm import artist_top_tags
    from app.catalog.identity import is_own_artist
    from app.home.lastfm_taste import _BROAD, lastfm_name

    sem = asyncio.Semaphore(6)
    out: dict[str, dict[str, float]] = {}

    async def one(a: str) -> None:
        name = names.get(a)
        if not name or await asyncio.to_thread(is_own_artist, a):
            return
        async with sem:
            try:
                tags = await artist_top_tags(lastfm_name(name))
            except Exception:  # noqa: BLE001
                return
        v = {t.lower(): (cnt / 100) * (0.4 if t.lower() in _BROAD else 1.0) for t, cnt in tags[:12] if cnt >= 10}
        if v:
            out[a] = v

    await asyncio.gather(*(one(a) for a in core))
    return out


def _cos(x: dict[str, float] | None, y: dict[str, float] | None) -> float | None:
    if not x or not y:
        return None
    num = sum(v * y.get(k, 0.0) for k, v in x.items())
    den = math.sqrt(sum(v * v for v in x.values())) * math.sqrt(sum(v * v for v in y.values()))
    return num / den if den else None


def _graph(sessions, core, tags, genres, long_art) -> dict[str, dict[str, float]]:
    n_sess: Counter = Counter()
    pair: Counter = Counter()
    for s in sessions:
        arts = [a for a in s if a in core]
        if len(arts) > 40:  # celodenní relace (rádio, import) -- slabý signál
            arts = sorted(arts, key=lambda a: -long_art.get(a, 0))[:40]
        for a in arts:
            n_sess[a] += s[a]
        if len(arts) < 2:
            continue
        w = 1.0 / math.log2(1 + len(arts))
        for i, a in enumerate(arts):
            for b in arts[i + 1:]:
                key = (a, b) if a < b else (b, a)
                pair[key] += w * min(s[a], s[b])
    nbrs: dict[str, list[tuple[float, str]]] = defaultdict(list)
    for (a, b), cnt in pair.items():
        if cnt < 1.0:
            continue
        sim = cnt / math.sqrt(n_sess[a] * n_sess[b])
        tc = _cos(tags.get(a), tags.get(b))
        if tc is not None:
            # Styl rozhoduje víc než společné relace (13. 10.: twenty one
            # pilots a bluegrass se letos střídaly a spadly do jedné scény).
            sim *= 0.05 + 0.95 * tc * tc
        else:
            gc = _cos(genres.get(a), genres.get(b))
            if gc is not None:
                sim *= 0.3 + 0.7 * gc
        nbrs[a].append((sim, b))
        nbrs[b].append((sim, a))
    adj: dict[str, dict[str, float]] = defaultdict(dict)
    for a, lst in nbrs.items():
        for sim, b in sorted(lst, reverse=True)[:NEIGHBOURS]:
            adj[a][b] = max(adj[a].get(b, 0.0), sim)
            adj[b][a] = max(adj[b].get(a, 0.0), sim)
    return adj


def _louvain(adj: dict[str, dict[str, float]], resolution: float, seed: int = 1) -> dict[str, str]:
    rng = random.Random(seed)
    node_of = {n: n for n in adj}
    graph = {n: dict(e) for n, e in adj.items()}
    while True:
        comm = {n: n for n in graph}
        k = {n: sum(e.values()) for n, e in graph.items()}
        m2 = sum(k.values()) or 1.0
        tot = dict(k)
        moved_any = improved = False
        improved = True
        while improved:
            improved = False
            order = sorted(graph)
            rng.shuffle(order)
            for n in order:
                cn = comm[n]
                links: Counter = Counter()
                for b, w in graph[n].items():
                    if b != n:
                        links[comm[b]] += w
                tot[cn] -= k[n]
                best, best_gain = cn, links.get(cn, 0.0) - resolution * tot[cn] * k[n] / m2
                for cc, w in links.items():
                    gain = w - resolution * tot[cc] * k[n] / m2
                    if gain > best_gain + 1e-12:
                        best, best_gain = cc, gain
                tot[best] += k[n]
                if best != cn:
                    comm[n] = best
                    improved = moved_any = True
        if not moved_any:
            break
        new_graph: dict[str, dict[str, float]] = defaultdict(dict)
        for n, e in graph.items():
            for b, w in e.items():
                ca, cb = comm[n], comm[b]
                new_graph[ca][cb] = new_graph[ca].get(cb, 0.0) + w
        node_of = {o: comm[s] for o, s in node_of.items()}
        graph = dict(new_graph)
    return node_of


def _merge_small(groups: dict[str, set[str]], adj: dict[str, dict[str, float]]) -> dict[str, set[str]]:
    """Skupiny menší než MIN_SCENE k té, se kterou mají nejsilnější vazby."""
    groups = {c: set(ms) for c, ms in groups.items()}
    for c in sorted(groups, key=lambda c: len(groups[c])):
        ms = groups.get(c)
        if ms is None or len(ms) >= MIN_SCENE:
            continue
        where = {a: cc for cc, mm in groups.items() if cc != c for a in mm}
        links: Counter = Counter()
        for a in ms:
            for b, w in adj.get(a, {}).items():
                if b in where:
                    links[where[b]] += w
        if links:
            target = links.most_common(1)[0][0]
            groups[target] |= ms
            del groups[c]
    return groups


def _debug_stage(stage, groups, names) -> None:
    import os

    probe = os.environ.get("SCENES_PROBE")
    if not probe:
        return
    for c, ms in groups.items():
        if any(names.get(a) == probe for a in ms):
            print(stage, len(ms), sorted(names.get(a, "?") for a in ms)[:40])


PURE_MIN = 0.15  # interpret se stylem tak vzdáleným od své scény jde jinam
PURE_GAIN = 0.15
PURE_GROUP = 0.4


def _centroid(members, tags, long_art, skip=None) -> dict[str, float]:
    acc: Counter = Counter()
    for a in members:
        if a == skip:
            continue
        w = long_art.get(a, 0.0) ** 0.5 + 1e-3
        for t, v in (tags.get(a) or {}).items():
            acc[t] += v * w
    return dict(acc)


SPLIT_EDGE = 0.35  # podobnost štítků pro rozdělení scény podle stylu


def _split_by_style(groups: dict[str, set[str]], tags, long_art) -> dict[str, set[str]]:
    """Scéna, ve které jsou stylem oddělené skupiny (twenty one pilots,
    bluegrass a hip-hop v jedné -- střídaly se v jednom roce), se rozdělí:
    souvislé skupiny podle podobnosti štítků uvnitř scény; části s aspoň MIN_SCENE
    interprety jsou samostatné scény, menší a bez štítků zůstanou největší."""
    out: dict[str, set[str]] = {}
    for c, ms in groups.items():
        tagged = [a for a in ms if a in tags]
        if len(tagged) < 2 * MIN_SCENE:
            out[c] = set(ms)
            continue
        adj: dict[str, dict[str, float]] = {a: {} for a in tagged}
        for i, a in enumerate(tagged):
            for b in tagged[i + 1:]:
                v = _cos(tags[a], tags[b]) or 0.0
                if v >= SPLIT_EDGE:
                    adj[a][b] = adj[b][a] = v
        # Souvislé skupiny podobných stylů (Louvain je drobil pod MIN_SCENE).
        parts: dict[str, set[str]] = defaultdict(set)
        seen: set[str] = set()
        for a in tagged:
            if a in seen or not adj[a]:
                continue
            stack, comp = [a], set()
            while stack:
                x = stack.pop()
                if x in comp:
                    continue
                comp.add(x)
                stack.extend(y for y in adj[x] if y not in comp)
            seen |= comp
            parts[a] = comp
        big = sorted((p for p in parts.values() if len(p) >= MIN_SCENE), key=lambda p: -sum(long_art.get(a, 0.0) for a in p))
        if len(big) < 2:
            out[c] = set(ms)
            continue
        cents = [_centroid(p, tags, long_art) for p in big]
        homes = [set(p) for p in big]
        for a in ms:
            if any(a in h for h in homes):
                continue
            i = max(range(len(homes)), key=lambda i: _cos(tags.get(a), cents[i]) or 0.0) if a in tags else 0
            homes[i].add(a)
        for h in homes:
            out[max(h, key=lambda a: long_art.get(a, 0.0))] = h
    return out


def _purify(groups: dict[str, set[str]], tags, long_art, rounds: int = 2) -> dict[str, set[str]]:
    """Styl uvnitř scény (13. 10.: XXXTENTACION a Eminem v bossa nově,
    twenty one pilots s bluegrassem -- společné relace z míchání celé
    knihovny je slepily). Interpret, jehož štítky skoro nesedí na zbytek
    scény, přejde do scény, kam stylem patří; když taková není, vytvoří
    s podobnými "vyhnanci" novou, a zbytek přejde k nejbližší."""
    groups = {c: set(ms) for c, ms in groups.items()}
    for _ in range(rounds):
        cents = {c: _centroid(ms, tags, long_art) for c, ms in groups.items()}
        moves: list[tuple[str, str, str | None]] = []
        for c, ms in groups.items():
            if len(ms) <= MIN_SCENE:
                continue
            for a in ms:
                if a not in tags:
                    continue
                own = _cos(tags[a], _centroid(ms, tags, long_art, skip=a)) or 0.0
                if own >= PURE_MIN:
                    continue
                best, best_c = own, None
                for cc, cent in cents.items():
                    if cc != c:
                        v = _cos(tags[a], cent) or 0.0
                        if v > best:
                            best, best_c = v, cc
                moves.append((a, c, best_c if best >= own + PURE_GAIN else None))
        if not moves:
            break
        exiles = []
        for a, src, dst in moves:
            groups[src].discard(a)
            if dst is not None:
                groups[dst].add(a)
            else:
                exiles.append(a)
        # Vyhnanci bez domova: podobní spolu (nová scéna), jinak k nejbližší.
        while exiles:
            seed = max(exiles, key=lambda a: long_art.get(a, 0.0))
            mates = [a for a in exiles if (_cos(tags[a], tags[seed]) or 0.0) >= PURE_GROUP]
            if len(mates) >= MIN_SCENE:
                groups[seed] = set(mates)
            else:
                cents = {c: _centroid(ms, tags, long_art) for c, ms in groups.items() if ms}
                for a in mates:
                    target = max(cents, key=lambda c: _cos(tags[a], cents[c]) or 0.0)
                    groups[target].add(a)
            exiles = [a for a in exiles if a not in mates]
        groups = {c: ms for c, ms in groups.items() if ms}
    return groups


def _years(act, scene_of: dict[str, str], canon) -> dict[str, Counter]:
    out: dict[str, Counter] = defaultdict(Counter)
    for t, rid in act.timeline:
        c = scene_of.get(canon(act.artist_of.get(rid)))
        if c:
            out[c][t.year] += 1
    return out


def describe(smap: SceneMap, names: dict[str, str] | None = None) -> str:
    """Čitelný výpis (ladění, `python -m app.home.scenes <profil>`)."""
    lines = []
    for i, s in enumerate(smap.scenes, 1):
        top = ", ".join((names or {}).get(a, a) for a in s.artists[:6])
        lines.append(
            f"{i:2}. {len(s.artists):3}+{len(s.tail):<4} {s.weight*100:4.1f}% teď {s.now*100:4.1f}% "
            f"{'SPÍ ' if s.dormant else '    '}{s.peak_year}-{s.last_year} | {s.label[:34]:34} | {top}"
        )
    return "\n".join(lines)


if __name__ == "__main__":
    import sys

    async def _main() -> None:
        smap = await compute(sys.argv[1], float(sys.argv[2]) if len(sys.argv) > 2 else RESOLUTION)
        ids = [a for s in smap.scenes for a in s.artists[:6]]
        names, _g = _artist_meta(ids)
        print(describe(smap, names))
        print(json.dumps({"scenes": len(smap.scenes), "dormant": sum(s.dormant for s in smap.scenes)}))

    asyncio.run(_main())
