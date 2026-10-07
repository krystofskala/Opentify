"""Plynulé přechody (bod 4): vzdálenost stylů, velký skok, navázání na
právě hrající skladbu, nálada podle zvuku, rozbor z ukázky Deezeru."""

import uuid

from sqlmodel import Session

from app.db import engine
from app.home import energy_flow as ef
from app.home.play_now import track_mood_fit
from app.models import Artist, Recording, TrackFeatures

_RUN = uuid.uuid4().hex[:8]
POP_PUNK = {"pop punk": 1.0, "alternative": 0.6, "punk": 0.4}
BOSSA = {"bossa nova": 1.0, "jazz": 0.7, "samba": 0.5}
EMO = {"pop punk": 0.8, "emo": 1.0, "alternative": 0.5}


def test_style_distance() -> None:
    assert ef.style_distance(POP_PUNK, POP_PUNK) < 0.01
    assert ef.style_distance(POP_PUNK, BOSSA) > 0.99
    assert ef.style_distance(POP_PUNK, EMO) < 0.5
    assert ef.style_distance(POP_PUNK, None) is None


def test_jump_catches_style_only_change() -> None:
    # YUNGBLUD -> Tenório Jr.: energie 0,78 -> 0,56, styl nic společného
    assert ef.is_jump(0.22, ef.style_distance(POP_PUNK, BOSSA))
    assert not ef.is_jump(0.22, ef.style_distance(POP_PUNK, EMO))
    assert not ef.is_jump(0.9, None)  # bez štítků nesoudit


def _track(name: str, energy: float) -> tuple[str, str]:
    with Session(engine) as s:
        a = Artist(name=f"{name} {_RUN}")
        s.add(a)
        s.flush()
        r = Recording(title=f"{name} song", artist_id=a.id)
        s.add(r)
        s.flush()
        s.add(TrackFeatures(recording_id=r.id, version=1, energy=energy, intro_energy=energy, outro_energy=energy, intro_level_db=-6, outro_level_db=-6))
        s.commit()
        return r.id, a.id


def test_order_continues_from_anchor_and_keeps_styles_together() -> None:
    punk_now, a0 = _track("Punk now", 0.8)
    punk2, a1 = _track("Punk two", 0.75)
    bossa1, a2 = _track("Bossa one", 0.4)
    bossa2, a3 = _track("Bossa two", 0.35)
    artist_of = {punk_now: a0, punk2: a1, bossa1: a2, bossa2: a3}
    styles = {a0: POP_PUNK, a1: EMO, a2: BOSSA, a3: BOSSA}
    out = ef.order([bossa1, punk2, bossa2], artist_of, anchor=punk_now, styles=styles)
    assert punk_now not in out and sorted(out) == sorted([bossa1, punk2, bossa2])
    assert out[0] == punk2  # po punku nejdřív punk, pak teprve bossa
    assert out[1:] in ([bossa1, bossa2], [bossa2, bossa1])
    jumps = ef.jumps(out, artist_of, styles, anchor=punk_now)
    assert len(jumps) == 1 and jumps[0][0] == 0  # jediný skok: punk -> bossa


def test_track_mood_fit() -> None:
    assert track_mood_fit("klid", 0.2) > 1 > track_mood_fit("klid", 0.9)
    assert track_mood_fit("energie", 0.9, 130) > track_mood_fit("energie", 0.9) > track_mood_fit("energie", 0.2)
    assert track_mood_fit("klid", None) == 1.0  # bez rozboru jen štítky
    assert track_mood_fit("prekvap", 0.9) == 1.0


def test_preview_features_never_overwrite_full_analysis() -> None:
    from app import preview_features

    rid, _a = _track("Full", 0.7)
    preview_features._store(rid, {"energy": 0.1})
    with Session(engine) as s:
        assert s.get(TrackFeatures, rid).energy == 0.7  # rozbor celého souboru zůstal
    with Session(engine) as s:
        r = Recording(title="Preview only " + _RUN)
        s.add(r)
        s.commit()
        rid2 = r.id
    preview_features._store(rid2, {"energy": 0.3, "bpm": 120, "bpm_confidence": 0.8})
    with Session(engine) as s:
        f = s.get(TrackFeatures, rid2)
        assert f.version == preview_features.PREVIEW_VERSION and f.energy == 0.3 and f.intro_energy == 0.3
