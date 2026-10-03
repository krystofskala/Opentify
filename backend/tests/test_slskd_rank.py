"""Výběr souboru ze Soulseeku na skutečných případech z auditu (2026-10-03)."""

from app.providers import SlskdProvider, TrackMetadata, _junk_reason, _track_no


def _resp(user: str, files: list[tuple[str, int, float | None]], free: bool = True) -> dict:
    return {
        "username": user,
        "hasFreeUploadSlot": free,
        "queueLength": 0,
        "uploadSpeed": 2_000_000,
        "files": [{"filename": f, "size": size, "length": length} for f, size, length in files],
    }


def _pick(track: TrackMetadata, responses: list[dict]) -> str | None:
    ranked = SlskdProvider()._rank(responses, track, interactive=False)
    return ranked[0][2]["filename"] if ranked else None


def test_harvest_moon_never_old_king():
    track = TrackMetadata(recording_id="x", title="Harvest Moon", artist_name="Neil Young", duration_ms=303_000, album_title=None)
    responses = [
        _resp("a", [("Music\\Neil Young - Harvest Moon\\Neil Young - Harvest Moon - 08 - Old King.flac", 20_000_000, 177)]),
        _resp("b", [("Music\\Neil Young\\Harvest Moon\\04 Harvest Moon.flac", 35_000_000, 304)]),
    ]
    assert _pick(track, responses).endswith("04 Harvest Moon.flac")


def test_wrong_song_only_means_nothing():
    track = TrackMetadata(recording_id="x", title="Believe", artist_name="Cher", duration_ms=239_000)
    responses = [_resp("a", [("Cher\\Backstage\\0104 - Reason to Believe.flac", 18_000_000, 238)])]
    assert _pick(track, responses) is None


def test_artist_required():
    track = TrackMetadata(recording_id="x", title="Radio", artist_name="Future", duration_ms=196_000)
    responses = [_resp("a", [("Music\\SPARKLEWOLF RADIO - 21 in the near future!.flac", 20_000_000, 196)])]
    assert _pick(track, responses) is None


def test_missing_length_rejected_when_duration_known():
    track = TrackMetadata(recording_id="x", title="Skin", artist_name="Rag'n'Bone Man", duration_ms=239_000)
    responses = [_resp("a", [("Rag'n'Bone Man\\Human\\03 Skin.flac", 30_000_000, None)])]
    assert _pick(track, responses) is None


def test_junk_files():
    assert _junk_reason("x\\._04 Harvest Moon.mp3", "._04 Harvest Moon.mp3", ".mp3", 4096, None, None)
    assert _junk_reason("a\\failed_imports\\incomplete\\the lakes.flac", "the lakes.flac", ".flac", 97_160, 211, None)
    assert _junk_reason("a\\Skin.mp3", "Skin.mp3", ".mp3", 617, None, None)
    # FLAC, který tvrdí 4 minuty, ale má 2 MB = useknutý.
    assert _junk_reason("a\\x.flac", "x.flac", ".flac", 2_000_000, 240, None)
    assert _junk_reason("a\\x.flac", "x.flac", ".flac", 30_000_000, 240, None) is None


def test_compilation_folder_loses_to_album():
    track = TrackMetadata(recording_id="x", title="Buffalo Stance", artist_name="Neneh Cherry", duration_ms=342_000, album_title="Raw Like Sushi")
    responses = [
        _resp("a", [("Now 1989 [FLAC]\\CD1\\16 Neneh Cherry - Buffalo Stance.flac", 30_000_000, 245)]),
        _resp("b", [("Neneh Cherry - Raw Like Sushi\\01 Buffalo Stance.flac", 40_000_000, 341)], free=False),
    ]
    assert "Raw Like Sushi" in _pick(track, responses)


def test_track_numbers():
    assert _track_no("07 - X.flac") == 7
    assert _track_no("0107 - X.flac") == 7
    assert _track_no("1-07 X.flac") == 7
    assert _track_no("Harvest Moon.flac") is None
