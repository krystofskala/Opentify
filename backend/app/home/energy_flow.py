"""Pořadí skladeb podle plynulosti energie (plán P3).

Konec jedné skladby má navazovat na začátek další -- po tichém dozvuku ne
hned řev. Okraje z rozboru zvuku (`TrackFeatures`, app/audio_features.py):
energie prvních / posledních 10 s skutečné hudby + jejich hlasitost vůči
špičce skladby; spolehlivě změřené tempo bez velkých skoků (půl / dvojnásobek
= stejné). Skladby bez rozboru: starý odhad z hlasitosti masteringu a obrysu
(ten řadil spíš podle éry nahrávky -- audit 7. 10.).

Skladby bez rozboru (ještě nestažené) dostanou průměr -- nevadí nikde.
Řazení: hladově "nejbližší další" + pár průchodů 2-opt; stejný interpret
vedle sebe stojí navíc (rozprostření jako dřív)."""

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


def _tempo_gap(a: float, b: float) -> float:
    """Relativní rozdíl temp, půl/dvojnásobek se bere jako stejné (0..1)."""
    gap = min(abs(a - b), abs(a - 2 * b), abs(2 * a - b)) / max(a, b)
    return min(1.0, gap / 0.15)


def order(ids: list[str], artist_of: dict[str, str]) -> list[str]:
    """Stejné skladby, plynulejší pořadí. První skladba zůstává první (mix
    začíná tím, čím začínal)."""
    if len(ids) < 3:
        return list(ids)
    with Session(engine) as session:
        # Nový rozbor má přednost, starý obrys jen pro skladby bez něj.
        edges = _edges(session, ids)
        new_edges, tempo = _feature_edges(session, ids)
        edges.update(new_edges)
    if len(edges) < 3:
        return list(ids)  # skoro nic není rozebrané -- neměnit
    mean_in = sum(e[0] for e in edges.values()) / len(edges)
    mean_out = sum(e[1] for e in edges.values()) / len(edges)

    def edge(r: str) -> tuple[float, float]:
        return edges.get(r, (mean_in, mean_out))

    def cost(a: str, b: str) -> float:
        c = abs(edge(a)[1] - edge(b)[0])
        if a in tempo and b in tempo:
            c += TEMPO_WEIGHT * _tempo_gap(tempo[a], tempo[b])
        if artist_of.get(a) and artist_of.get(a) == artist_of.get(b):
            c += SAME_ARTIST_PENALTY
        return c

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
        return sum(abs(edges[a][1] - edges[b][0]) for a, b in pairs) / len(pairs) if pairs else 0.0

    # Jen když je to opravdu plynulejší (skladby bez rozboru a stejní
    # interpreti můžou výsledek zhoršit -- živě Denní mix 5 o 34 %).
    return path if measured(path) <= measured(list(ids)) else list(ids)


def roughness(ids: list[str]) -> float | None:
    """Průměrný skok energie mezi sousedy (pro měření)."""
    with Session(engine) as session:
        edges = _edges(session, ids)
    pairs = [(a, b) for a, b in zip(ids, ids[1:]) if a in edges and b in edges]
    if not pairs:
        return None
    return sum(abs(edges[a][1] - edges[b][0]) for a, b in pairs) / len(pairs)
