"""Kam dál, když vlna opadne (7v, 13. 10.).

Když vlna (app/home/waves.py) opadá nebo nedávno skončila, připraví se tři
cesty dál -- skoky u vlastníka byly ze 40 % daleké a nejbližší styl další
vlnu skoro nikdy nepředpověděl, proto ne jedna "podobná" cesta:

- **Vedle**: noví interpreti blízko vlny (podobné skladby Last.fm, mimo
  scény vlny);
- **Návrat**: spící scéna, která už měla vlnu (před 90+ dny), daleko od
  opadající -- oblíbené odtamtud + trochu nového;
- **Skok**: daleká, jen trochu známá scéna s nedávnou jiskrou (poslechy,
  chycené skladby), vážená podle toho, kam profil skákal z podobných vln.

Cesty jsou samostatné mixy "Kam dál · Vedle / Návrat / Skok" (13. 10.:
"denní mixy jsou denní mixy, udělat speciálně něco nového") -- jen dokud
vlna opadá nebo nedávno skončila, pak zmizí. Do Pusť teď a Objevů se cesty
přimíchávají v dávce podle typu posluchače (pravidlo 13. 10.: nikomu
vzdálenější nabídky úplně neskrývat, jen nenutit): vlnař plně, smíšený
občas, stálý vzácně. Počítá se jednou denně (plánovač), uloží se do
`kamdal:{profil}`.
"""

from __future__ import annotations

import asyncio
import logging
import random
from collections import Counter
from datetime import date, datetime, timedelta

from sqlmodel import Session

from app.db import engine
from app.utils import utcnow

logger = logging.getLogger(__name__)

PATH_SIZE = 30
RETURN_MIN_DAYS = 90
NEAR_MAX_SIM = 0.33  # Návrat: aspoň takhle daleko od vlny
FAR_MAX_SIM = 0.16  # Skok: pod mediánem podobnosti všech dvojic scén
HANDOVER_DAYS = 45
SPARK_DAYS = 90
HOLD_AFTER_END_DAYS = 30
# Kolik nabídek podle typu posluchače (pravděpodobnost za den / várku).
DOSE = {"wave": 1.0, "mixed": 0.4, "steady": 0.15, "unknown": 0.0}


def _key(user_id: str) -> str:
    return f"kamdal:{user_id}"


def load(user_id: str) -> dict:
    from app.models import HomeSnapshot

    with Session(engine) as session:
        row = session.get(HomeSnapshot, _key(user_id))
    return dict(row.payload or {}) if row else {}


def _save(user_id: str, payload: dict) -> None:
    from app.models import HomeSnapshot

    with Session(engine) as session:
        row = session.get(HomeSnapshot, _key(user_id)) or HomeSnapshot(key=_key(user_id), payload={})
        row.payload = payload
        row.generated_at = utcnow()
        session.add(row)
        session.commit()


def dose(user_id: str) -> float:
    data = load(user_id)
    return DOSE.get(data.get("listener") or "unknown", 0.0) if data.get("paths") else 0.0


def path_scene(user_id: str, day: str) -> tuple[str, str, str] | None:
    """(scéna, cesta, popis vlny) pro dnešní mix: Návrat a Skok se střídají
    po dnech; podle dávky typu posluchače. None = dnes nic."""
    data = load(user_id)
    paths = data.get("paths") or {}
    rng = random.Random(f"{user_id}:{day}:kamdal")
    if not paths or rng.random() >= dose(user_id):
        return None
    order = ["navrat", "skok"] if date.fromisoformat(day).toordinal() % 2 else ["skok", "navrat"]
    for name in order:
        p = paths.get(name) or {}
        if p.get("scene"):
            return p["scene"], name, (data.get("wave") or {}).get("title", "")
    return None


def path_tracks(user_id: str, names: tuple[str, ...] = ("vedle", "skok", "navrat")) -> dict[str, list[str]]:
    data = load(user_id)
    return {n: list((data.get("paths") or {}).get(n, {}).get("ids") or []) for n in names}


async def _scene_vectors(smap, names: dict[str, str]) -> dict[str, dict[str, float]]:
    from app.home import scenes

    core = {a for s in smap.scenes for a in s.artists[:12]}
    vec = await scenes._tag_vectors(core, names)
    out: dict[str, dict[str, float]] = {}
    for s in smap.scenes:
        acc: Counter = Counter()
        for i, a in enumerate(s.artists[:12]):
            for t, v in (vec.get(a) or {}).items():
                acc[t] += v / (1 + 0.15 * i)
        out[s.id] = dict(acc)
    return out


def _sum_vec(vs: list[dict[str, float]]) -> dict[str, float]:
    acc: Counter = Counter()
    for v in vs:
        acc.update(v)
    return dict(acc)


async def compute(user_id: str, today: date | None = None) -> dict:
    """`today`: přehrání historie k danému dni (ověření)."""
    from app.home import activation as av
    from app.home import lastfm_taste as lt
    from app.home import novelty, scenes, waves
    from app.home.caught import caught_tracks
    from app.home.personal_mixes import _weighted_order

    act = await asyncio.to_thread(av.cached, user_id)
    smap = await asyncio.to_thread(scenes.load, user_id)
    if not smap.scenes:
        return {"state": "none", "listener": "unknown"}
    names = await asyncio.to_thread(_artist_names, list({a for s in smap.scenes for a in s.artists[:12]}))
    vecs = await _scene_vectors(smap, names)

    def sim(a: str, b: str) -> float:
        return scenes._cos(vecs.get(a), vecs.get(b)) or 0.0

    rep = await asyncio.to_thread(waves.detect, act, smap, today, waves.MIN_LEN, sim)
    base = {"listener": rep.listener, "day": utcnow().date().isoformat(),
            "waveDayShare": round(rep.wave_day_share, 2), "scenesPerMonth": rep.scenes_per_month}
    wave = rep.current()
    today = today or utcnow().date()
    base["companions"] = _companions(rep, act, smap, today, sim=sim)
    if wave is None or (wave.state == "ended" and (today - wave.end).days > HOLD_AFTER_END_DAYS):
        live = [w for w in rep.waves if w.state in ("rising", "peak")]
        return {**base, "state": live[-1].state if live else "none",
                "wave": _wave_info(live[-1], smap, names) if live else None}
    family = set(wave.scenes)
    by_id = smap.by_id()
    xvec = _sum_vec([vecs.get(s, {}) for s in family])

    def sim_x(sid: str) -> float:
        return scenes._cos(xvec, vecs.get(sid)) or 0.0

    rng = random.Random(f"{user_id}:{base['day']}:kamdal")
    family_artists = {a for s in family for a in (by_id[s].artists + by_id[s].tail) if s in by_id}
    heard = set(act.total)
    paths: dict[str, dict] = {}

    # --- Vedle: podobné skladby k vlně od interpretů mimo ni.
    seeds = []
    for a in wave.artists[:6]:
        mine = [r for r in act.total if act.artist_of.get(r) == a]
        if mine:
            seeds.append(max(mine, key=lambda r: act.long.get(r, 0.0)))
    skip_names = {names.get(a) or "" for a in family_artists if names.get(a)}
    try:
        near = await lt.similar_track_ids(seeds, heard, rng, PATH_SIZE * 2, skip_artists=skip_names, deadline=20.0)
    except Exception:  # noqa: BLE001
        near = []
    near = await asyncio.to_thread(novelty.filter_new, user_id, near, act)
    near = [r for r in near if act.artist_of.get(r) not in family_artists][:PATH_SIZE]
    if near:
        paths["vedle"] = {"ids": near}

    # Minulé předávky vln (A -> B) pro Skok: kam profil skákal z podobných vln.
    handovers = []
    for i, a in enumerate(rep.waves):
        for b in rep.waves[i + 1:]:
            if a.peak <= b.onset <= a.end + timedelta(days=HANDOVER_DAYS) and b.scene not in a.scenes:
                handovers.append((a.scene, b.scene))
                break
    waved = {}
    for w in rep.waves:
        for s in w.scenes:
            waved[s] = max(waved.get(s, w.end), w.end)
    shown = await asyncio.to_thread(scenes.shown_days, user_id)

    # --- Návrat: spící scéna s dřívější vlnou, daleko od opadající.
    cands = []
    for s in smap.scenes:
        if s.id in family or not s.dormant or s.id not in waved:
            continue
        if (today - waved[s.id]).days < RETURN_MIN_DAYS or sim_x(s.id) >= NEAR_MAX_SIM:
            continue
        pause = 0.3 if s.id in shown and (today - date.fromisoformat(shown[s.id])).days < scenes.SHOWN_COOLDOWN_DAYS else 1.0
        cands.append((s.weight ** 0.7 * pause * rng.uniform(0.8, 1.2), s))
    if cands:
        scene = max(cands, key=lambda x: x[0])[1]
        members = set(scene.artists) | set(scene.tail)
        from app.home import guard

        gd = await asyncio.to_thread(guard.load, user_id)  # společný filtr (OP-ALG1)
        pool = [r for r in act.total if act.artist_of.get(r) in members and gd.allowed(r, act.artist_of.get(r))]
        former = set(act.former_loves()[:300])
        fam = _weighted_order(
            pool,
            lambda r: ((act.long.get(r, 0.0) ** 0.5) + (0.5 if r in former else 0.0)) * gd.weight(r, act.artist_of.get(r))
            + 1e-6,
            rng,
        )
        fam = _one_per_artist(fam, act.artist_of, 3)[: PATH_SIZE * 3 // 4]
        paths["navrat"] = {"scene": scene.id, "ids": fam, "label": scene.label, "lastYear": scene.last_year}

    # --- Skok: daleká, lehce osahaná scéna s jiskrou.
    since = datetime.combine(today, datetime.min.time(), tzinfo=act.now.tzinfo) - timedelta(days=SPARK_DAYS)
    scene_of = smap.scene_of()
    spark: Counter = Counter()
    spark_tracks: dict[str, Counter] = {}
    for t, rid in act.timeline:
        if since <= t <= since + timedelta(days=SPARK_DAYS + 1):
            s = scene_of.get(act.artist_of.get(rid))
            if s:
                spark[s] += 1
                spark_tracks.setdefault(s, Counter())[rid] += 1
    for rid in await asyncio.to_thread(caught_tracks, user_id, act):
        s = scene_of.get(act.artist_of.get(rid))
        if s:
            spark[s] += 3
    rank = {s.id: i for i, s in enumerate(sorted(smap.scenes, key=lambda s: -s.weight))}
    jumps = []
    navrat = (paths.get("navrat") or {}).get("scene")
    for s in smap.scenes:
        if s.id in family or s.id == navrat or not spark[s.id] or sim_x(s.id) >= FAR_MAX_SIM:
            continue
        hist = 1.0 + sum(sim_x(a) * sim(s.id, b) for a, b in handovers)
        light = 1.0 if rank.get(s.id, 0) >= 10 else 0.5
        jumps.append((spark[s.id] ** 0.5 * hist * light * rng.uniform(0.8, 1.2), s))
    if jumps:
        scene = max(jumps, key=lambda x: x[0])[1]
        entry = [r for r, _ in spark_tracks.get(scene.id, Counter()).most_common(3)]
        members = set(scene.artists) | set(scene.tail)
        jseeds = entry + [r for r in _weighted_order(
            [r for r in act.total if act.artist_of.get(r) in members], lambda r: act.long.get(r, 0.0) + 1e-6, rng
        ) if r not in entry][:3]
        try:
            new = await lt.similar_track_ids(jseeds, heard, rng, PATH_SIZE, deadline=20.0)
        except Exception:  # noqa: BLE001
            new = []
        new = await asyncio.to_thread(novelty.filter_new, user_id, new, act)
        paths["skok"] = {"scene": scene.id, "ids": entry + new[: PATH_SIZE - len(entry)], "label": scene.label,
                         "lastYear": scene.last_year}
    # Každá cesta plynule, i s novými (OP-ALG1 C); první skladba zůstává.
    from app.home import energy_flow
    from app.home.personal_mixes import _artists_of

    for p in paths.values():
        ids = p.get("ids") or []
        path_artist_of = {**await asyncio.to_thread(_artists_of, ids), **act.artist_of}
        p["ids"] = await energy_flow.smooth(ids, path_artist_of, {r for r in ids if r not in heard})
    info = _wave_info(wave, smap, names)
    return {**base, "state": wave.state, "wave": info, "paths": paths}


MIXES = {
    "vedle": ("Kam dál · Vedle", "noví interpreti blízko ní"),
    "navrat": ("Kam dál · Návrat", "zpátky k {label}, naposledy {year}"),
    "skok": ("Kam dál · Skok", "jinam: {label}, kam jsi poslední dobou nakoukl"),
}


def _save_mixes(user_id: str, data: dict) -> None:
    """Tři mixy cest; bez opadající vlny prázdné (na Domů se neukážou)."""
    from app.home import generators as g
    from app.home.personal_mixes import _clear_playlists
    from app.models import PlaylistKind

    from app.home import activation as av

    paths = data.get("paths") or {}
    wave = (data.get("wave") or {}).get("title") or "vlně"
    heard = av.cached(user_id).total
    empty = []
    for name, (title, what) in MIXES.items():
        p = paths.get(name) or {}
        ids = p.get("ids") or []
        source = f"personal:kamdal-{name}"
        if len(ids) < 8:
            empty.append(source)
            continue
        label = (p.get("label") or "").split(",")[0].strip()
        desc = what.format(label=label or "staré scéně", year=p.get("lastYear") or "dávno")
        g._save_playlist(
            owner=user_id, source=source, title=title, description=f"Po vlně {wave}: {desc}",
            kind=PlaylistKind.PERSONAL_MIX, section="mixes", recording_ids=ids,
            cover_urls=g._covers_for(ids), ttl=timedelta(days=2),
            origins={r: "known" if r in heard else "new:lastfm" for r in ids},
        )
    if empty:
        _clear_playlists(user_id, empty)


COMPANION_LIFT = 1.5
SIBLING_SIM = 0.5
COMPANION_MIN_PLAYS = 10


def _companions(rep, act, smap, today: date, n: int = 3, sim=None) -> list[str]:
    """Doprovodné scény k vlně, která teď běží (13. 10.: "když mám jazzovou
    vlnu, v minulosti jsem u toho poslouchal i jinou sekci -- ta by mohla být
    v jiném denním mixu"): co se hrálo během dřívějších vln téže scény
    nápadně víc než jindy. Bez dřívější vlny téže scény: během té současné."""
    live = [w for w in rep.waves if w.state in ("rising", "peak", "fading")]
    if not live:
        return []
    now = live[-1]
    family = set(now.scenes)
    past = [w for w in rep.waves if w is not now and family & set(w.scenes)] or [now]
    scene_of = smap.scene_of()
    during: Counter = Counter()
    overall: Counter = Counter()
    total_during = total = 0
    spans = [(w.onset, min(w.end, today)) for w in past]
    for t, rid in act.timeline:
        d = t.date()
        if d > today:
            break
        s = scene_of.get(act.artist_of.get(rid))
        if not s or s in family:
            continue
        overall[s] += 1
        total += 1
        if any(a <= d <= b for a, b in spans):
            during[s] += 1
            total_during += 1
    if not total_during:
        return []
    scored = []
    for s, k in during.items():
        lift = (k / total_during) / max(overall[s] / max(total, 1), 1e-6)
        # Stylem skoro totéž co vlna (pop punk vs. punk rock) není doprovod.
        close = sim is not None and max((sim(s, f) for f in family), default=0.0) >= SIBLING_SIM
        if k >= COMPANION_MIN_PLAYS and lift >= COMPANION_LIFT and not close:
            scored.append((k * lift, s))
    return [s for _x, s in sorted(scored, reverse=True)[:n]]


def companions(user_id: str) -> list[str]:
    return list(load(user_id).get("companions") or [])


def _one_per_artist(ids: list[str], artist_of: dict, cap: int) -> list[str]:
    seen: Counter = Counter()
    out = []
    for r in ids:
        a = artist_of.get(r)
        if seen[a] < cap:
            seen[a] += 1
            out.append(r)
    return out


def _wave_info(wave, smap, names: dict[str, str]) -> dict:
    by_id = smap.by_id()
    label = (by_id[wave.scene].label.split(",")[0].strip() if wave.scene in by_id else "")
    top = [names.get(a) for a in wave.artists[:2] if names.get(a)]
    title = " a ".join(x for x in (", ".join(top), label) if x)
    return {**wave.to_json(), "title": title}


def _artist_names(artist_ids: list[str]) -> dict[str, str]:
    from sqlmodel import select

    from app.models import Artist

    with Session(engine) as session:
        return {a: n for a, n in session.exec(select(Artist.id, Artist.name).where(Artist.id.in_(artist_ids))).all()}  # type: ignore[attr-defined]


async def build() -> int:
    """Plánovač: jednou denně pro aktuální profil."""
    from app.home import generators as g

    from app.home import scenes

    user_id = g.home_user()
    today = utcnow().date().isoformat()
    stamp = await asyncio.to_thread(scenes._stamp, user_id)
    prev = load(user_id)
    if prev.get("day") == today and prev.get("scenesStamp") == stamp:
        return 0  # dnes hotovo a mapa scén se nezměnila (id scén platí)
    try:
        data = await compute(user_id)
    except Exception:  # noqa: BLE001
        logger.exception("kam dál: výpočet")
        return 0
    data["day"] = today
    data["scenesStamp"] = stamp
    await asyncio.to_thread(_save, user_id, data)
    await asyncio.to_thread(_save_mixes, user_id, data)
    paths = data.get("paths") or {}
    logger.info(
        "kam dál: %s, vlna %s (%s), cesty %s", data.get("listener"), (data.get("wave") or {}).get("title"),
        data.get("state"), {k: len(v.get("ids") or []) for k, v in paths.items()},
    )
    return sum(len(v.get("ids") or []) for v in paths.values())
