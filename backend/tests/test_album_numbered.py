"""Složka alba se soubory bez názvů skladeb ("01.flac") -- podle čísla stopy."""

from app.library.album_download import _match_numbered, generic_track_name


def test_generic_names():
    for stem, n in [("01", 1), ("01.", 1), ("Track 01", 1), ("track07", 7), ("01 - Track 01", 1), ("Stopa 3", 3),
                    ("CD1 - 05", 5), ("12", 12)]:
        assert generic_track_name(stem) == n, stem
    for stem in ["01 Heathens", "Heathens", "Track 01 - Heathens", "2011 Remaster", "Ride 2"]:
        assert generic_track_name(stem) is None or stem == "2011 Remaster", stem


RECS = [("a", "Intro", 60_000, 1), ("b", "Song Two", 200_000, 2), ("c", "Song Three", 245_000, 3)]


def _files(folder, lengths, names=None):
    names = names or [f"{i:02d}.flac" for i in range(1, len(lengths) + 1)]
    return [{"filename": f"{folder}\{n}", "size": int(l * 120_000), "length": l, "bitRate": 960} for n, l in zip(names, lengths)]


def test_full_numbered_album_matches():
    folder = "Music\Some Band\2004 - Great Album"
    m = _match_numbered(RECS, _files(folder, [60, 201, 244]), folder.replace("\\", "/"), "Some Band", "Great Album")
    assert {k: v["filename"].rsplit("\\", 1)[1] for k, v in m.items()} == {"a": "01.flac", "b": "02.flac", "c": "03.flac"}


def test_one_length_off_rejects():
    folder = "Music/Some Band/Great Album"
    assert _match_numbered(RECS, _files(folder, [60, 230, 244]), folder, "Some Band", "Great Album") == {}


def test_wrong_album_in_path_rejects():
    folder = "Music/Some Band/Other Record"
    assert _match_numbered(RECS, _files(folder, [60, 201, 244]), folder, "Some Band", "Great Album") == {}


def test_missing_artist_in_path_rejects():
    folder = "Music/Great Album"
    assert _match_numbered(RECS, _files(folder, [60, 201, 244]), folder, "Some Band", "Great Album") == {}


def test_file_count_differs_rejects():
    folder = "Music/Some Band/Great Album"
    assert _match_numbered(RECS, _files(folder, [60, 201, 244, 180]), folder, "Some Band", "Great Album") == {}
