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
