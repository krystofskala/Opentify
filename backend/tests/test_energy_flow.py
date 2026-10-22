"""Řazení podle plynulosti energie (P3): menší skoky, stejné skladby."""
import uuid

from sqlmodel import Session

from app.db import engine
from app.home import energy_flow
from app.loudness import encode_waveform
from app.models import MediaAsset, MediaAssetStatus, Recording

_RUN = uuid.uuid4().hex[:8]


def _track(intro: int, outro: int, gain: float) -> str:
    with Session(engine) as s:
        r = Recording(title=f"E {_RUN} {intro}-{outro}")
        s.add(r)
        s.flush()
        wave = [intro] * 8 + [200] * 104 + [outro] * 8
        s.add(MediaAsset(recording_id=r.id, status=MediaAssetStatus.AVAILABLE, waveform=encode_waveform(wave),
                         loudness_gain_db=gain))
        s.commit()
        return r.id


def test_order_reduces_jumps_and_keeps_tracks():
    # tichá, hlasitá, tichá, hlasitá... -> po seřazení navazují
    ids = [_track(30, 40, 6.0), _track(250, 250, -4.0), _track(40, 30, 6.0), _track(240, 250, -4.0),
           _track(35, 45, 6.0), _track(250, 240, -4.0)]
    ordered = energy_flow.order(ids, {})
    assert sorted(ordered) == sorted(ids) and ordered[0] == ids[0]
    assert energy_flow.roughness(ordered) < energy_flow.roughness(ids)


def test_without_analysis_order_is_unchanged():
    assert energy_flow.order(["a", "b", "c", "d"], {}) == ["a", "b", "c", "d"]


def test_repair_fixes_only_rough_jumps():
    # OP-ALG1: pořadí zůstane, jen skladba za hrubým skokem se prohodí s bližší.
    ids = [_track(100, 100, 0.0) for _ in range(6)]
    artist_of = dict(zip(ids, ["folk1", "punk", "folk2", "folk3", "folk4", "folk5"]))
    styles = {a: {"folk": 1.0} for a in ("folk1", "folk2", "folk3", "folk4", "folk5")} | {"punk": {"pop punk": 1.0}}
    out = energy_flow.repair(ids, artist_of, styles)
    assert sorted(out) == sorted(ids) and out[0] == ids[0]
    assert len(energy_flow.jumps(ids, artist_of, styles)) == 2
    assert out[-1] == ids[1] and len(energy_flow.jumps(out, artist_of, styles)) == 1  # punk na konec, folk drží
    smooth_ids = [ids[0], ids[2], ids[3], ids[4]]
    assert energy_flow.repair(smooth_ids, artist_of, styles) == smooth_ids


def test_off_style_drops_only_far_new_tracks():
    styles = {"folk1": {"folk": 1.0, "indie folk": 0.6}, "folk2": {"folk": 0.8},
              "near": {"indie folk": 1.0, "folk": 0.5}, "far": {"pop punk": 1.0}}
    artist_of = {"n1": "near", "n2": "far", "n3": "untagged"}
    assert energy_flow.off_style(["n1", "n2", "n3"], artist_of, styles, {"folk1", "folk2"}) == {"n2"}
    assert energy_flow.off_style(["n2"], artist_of, styles, set()) == set()
