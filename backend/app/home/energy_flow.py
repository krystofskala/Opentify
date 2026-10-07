"""Pořadí skladeb podle plynulosti energie (plán P3).

Konec jedné skladby má navazovat na začátek další -- po tichém dozvuku ne
hned řev. Okraje z rozboru zvuku (`TrackFeatures`, app/audio_features.py):
energie prvních / posledních 10 s skutečné hudby + jejich hlasitost vůči
špičce skladby; spolehlivě změřené tempo bez velkých skoků (půl / dvojnásobek
= stejné). Skladby bez rozboru: starý odhad z hlasitosti masteringu a obrysu
(ten řadil spíš podle éry nahrávky -- audit 7. 10.).

Skladby bez rozboru (ještě nestažené) dostanou průměr -- nevadí nikde.
Řazení: hladově "nejbližší další" + pár průchodů 2-opt; stejný interpret
vedle sebe stojí navíc (rozprostření jako dřív).

Od 7. 10. (opentify-notes/rozbor-zvuku-navrh-2026-10-07.md) i **vzdálenost
stylů** (štítky Last.fm interpretů): YUNGBLUD -> Tenório Jr. energií skoro
nevybočí (0,78 -> 0,56), ale pop-punk -> brazilský jazz za sebou ruší. A
navazuje se od skladby, která právě hraje (`anchor`), takže i hranice mezi
várkami nekonečného hraní je plynulá."""

from __future__ import annotations

from sqlmodel import Session, select

from app.db import engine
from app.loudness import TARGET_LUFS, _UNMEASURABLE, decode_waveform
from app.models import MediaAsset

EDGE_BUCKETS = 8
SAME_ARTIST_PENALTY = 0.5


def _edges(session: Session, ids: list[str]) -> dict[str, tuple[float, float]]:
    out: dict[str, tuple[float, float]] = {}
    for i in range(0, len(ids), 500):
        for a in session.exec(select(MediaAsset).where(MediaAsset.recording_id.in_(ids[i : i + 500]))).all():  # type: ignore[attr-defined]
            wave = decode_waveform(a.waveform)
            gain = a.loudness_gain_db
            if not wave or gain is None or gain == _UNMEASURABLE:
                continue
            lufs = TARGET_LUFS - gain  # tišší skladba = větší korekce
            level = min(1.0, max(0.0, (lufs + 22.0) / 16.0))  # -22..-6 LUFS -> 0..1
            intro = sum(wave[:EDGE_BUCKETS]) / (EDGE_BUCKETS * 255)
            outro = sum(wave[-EDGE_BUCKETS:]) / (EDGE_BUCKETS * 255)
            out[a.recording_id] = (level * (0.4 + 0.6 * intro), level * (0.4 + 0.6 * outro))
    return out


def _feature_edges(session: Session, ids: list[str]) -> tuple[dict[str, tuple[float, float]], dict[str, float]]:
    """Okraje z rozboru zvuku (app/audio_features.py): energie začátku/konce
    + jejich hlasitost vůči špičce skladby (tichý nástup / dozvuk). Vrátí
    (okraje, spolehlivé tempo)."""
    from app.models import TrackFeatures

    edges: dict[str, tuple[float, float]] = {}
    tempo: dict[str, float] = {}

    def level(db: float | None) -> float:
        return min(1.0, max(0.0, ((db if db is not None else -12.0) + 30.0) / 27.0))  # -30..-3 dB -> 0..1

    for i in range(0, len(ids), 500):
        for f in session.exec(select(TrackFeatures).where(TrackFeatures.recording_id.in_(ids[i : i + 500]))).all():  # type: ignore[attr-defined]
            if f.intro_energy is None or f.outro_energy is None:
                continue
            edges[f.recording_id] = (
                0.6 * f.intro_energy + 0.4 * level(f.intro_level_db),
                0.6 * f.outro_energy + 0.4 * level(f.outro_level_db),
            )
            if f.bpm and (f.bpm_confidence or 0) >= TEMPO_MIN_CONFIDENCE:
                tempo[f.recording_id] = f.bpm
    return edges, tempo


TEMPO_MIN_CONFIDENCE = 0.5
TEMPO_WEIGHT = 0.3
STYLE_WEIGHT = 0.6
# Velký skok: styly nemají skoro nic společného (YUNGBLUD -> Tenório Jr.,
# energie jen 0,78 -> 0,56), nebo hodně jiná energie a k tomu jiný styl.
JUMP_STYLE = 0.9
JUMP_STYLE_WITH_ENERGY = 0.6
JUMP_ENERGY = 0.5


def is_jump(energy_gap: float | None, style_dist: float | None) -> bool:
    if style_dist is None:
        return False
    return style_dist >= JUMP_STYLE or (energy_gap is not None and energy_gap >= JUMP_ENERGY and style_dist >= JUMP_STYLE_WITH_ENERGY)


def style_distance(a: dict[str, float] | None, b: dict[str, float] | None) -> float | None:
    """1 - kosinová podobnost stylových štítků dvou interpretů (0 = stejné,
    1 = nic společného); None, když u jednoho štítky nejsou."""
    if not a or not b:
        return None
    dot = sum(v * b.get(k, 0.0) for k, v in a.items())
    na = sum(v * v for v in a.values()) ** 0.5
    nb = sum(v * v for v in b.values()) ** 0.5
    return 1.0 - dot / (na * nb) if na and nb else None


def _tempo_gap(a: float, b: float) -> float:
    """Relativní rozdíl temp, půl/dvojnásobek se bere jako stejné (0..1)."""
    gap = min(abs(a - b), abs(a - 2 * b), abs(2 * a - b)) / max(a, b)
    return min(1.0, gap / 0.15)


def _model(ids: list[str]) -> tuple[dict[str, tuple[float, float]], dict[str, float]]:
    with Session(engine) as session:
        # Nový rozbor má přednost, starý obrys jen pro skladby bez něj.
        edges = _edges(session, ids)
        new_edges, tempo = _feature_edges(session, ids)
        edges.update(new_edges)
    return edges, tempo


def order(
    ids: list[str],
    artist_of: dict[str, str],
    anchor: str | None = None,
    styles: dict[str, dict[str, float]] | None = None,
) -> list[str]:
    """Stejné skladby, plynulejší pořadí. Bez `anchor` zůstává první skladba
    první (mix začíná tím, čím začínal); s `anchor` (právě hraje, není ve
    výsledku) se navazuje na něj. `styles` = interpret -> stylové štítky."""
    if len(ids) < (2 if anchor else 3):
        return list(ids)
    full = ([anchor] if anchor else []) + [r for r in ids if r != anchor]
    edges, tempo = _model(full)
    if len(edges) < 3:
        return list(ids)  # skoro nic není rozebrané -- neměnit
    mean_in = sum(e[0] for e in edges.values()) / len(edges)
    mean_out = sum(e[1] for e in edges.values()) / len(edges)
    styles = styles or {}

    def edge(r: str) -> tuple[float, float]:
        return edges.get(r, (mean_in, mean_out))

    def cost(a: str, b: str) -> float:
        c = abs(edge(a)[1] - edge(b)[0])
        if a in tempo and b in tempo:
            c += TEMPO_WEIGHT * _tempo_gap(tempo[a], tempo[b])
        if artist_of.get(a) and artist_of.get(a) == artist_of.get(b):
            c += SAME_ARTIST_PENALTY
        d = style_distance(styles.get(artist_of.get(a, "")), styles.get(artist_of.get(b, "")))
        if d is not None:
            c += STYLE_WEIGHT * d
        return c

    ids = full
    rest = list(ids[1:])
    path = [ids[0]]
    while rest:
        nxt = min(rest, key=lambda r: cost(path[-1], r))
        path.append(nxt)
        rest.remove(nxt)

    def total(p: list[str]) -> float:
        return sum(cost(p[i], p[i + 1]) for i in range(len(p) - 1))

    best = total(path)
    for _ in range(3):  # 2-opt, pár průchodů stačí
        improved = False
        for i in range(1, len(path) - 2):
            for j in range(i + 1, len(path) - 1):
                cand = path[:i] + path[i : j + 1][::-1] + path[j + 1 :]
                t = total(cand)
                if t + 1e-9 < best:
                    path, best, improved = cand, t, True
        if not improved:
            break

    def measured(p: list[str]) -> float:
        pairs = [(a, b) for a, b in zip(p, p[1:]) if a in edges and b in edges]
        energy = sum(abs(edges[a][1] - edges[b][0]) for a, b in pairs) / len(pairs) if pairs else 0.0
        if not styles:
            return energy
        dists = [d for a, b in zip(p, p[1:]) if (d := style_distance(styles.get(artist_of.get(a, "")), styles.get(artist_of.get(b, "")))) is not None]
        return energy + STYLE_WEIGHT * (sum(dists) / len(dists) if dists else 0.0)

    # Jen když je to opravdu plynulejší (skladby bez rozboru a stejní
    # interpreti můžou výsledek zhoršit -- živě Denní mix 5 o 34 %).
    best_path = path if measured(path) <= measured(list(ids)) else list(ids)
    return best_path[1:] if anchor else best_path


def jumps(
    ids: list[str], artist_of: dict[str, str], styles: dict[str, dict[str, float]] | None, anchor: str | None = None
) -> list[tuple[int, float, float | None]]:
    """Velké skoky v pořadí: (index skladby, PO které skok přijde v `ids`,
    skok energie, vzdálenost stylů). Index -1 = skok hned od `anchor`."""
    full = ([anchor] if anchor else []) + list(ids)
    edges, _tempo = _model(full)
    out = []
    for i, (a, b) in enumerate(zip(full, full[1:])):
        e = abs(edges[a][1] - edges[b][0]) if a in edges and b in edges else None
        d = style_distance((styles or {}).get(artist_of.get(a, "")), (styles or {}).get(artist_of.get(b, "")))
        if is_jump(e, d):
            out.append((i - (1 if anchor else 0), e if e is not None else 0.0, d))
    return out


def roughness(ids: list[str]) -> float | None:
    """Průměrný skok energie mezi sousedy (pro měření)."""
    with Session(engine) as session:
        edges = _edges(session, ids)
    pairs = [(a, b) for a, b in zip(ids, ids[1:]) if a in edges and b in edges]
    if not pairs:
        return None
    return sum(abs(edges[a][1] - edges[b][0]) for a, b in pairs) / len(pairs)
