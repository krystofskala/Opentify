"""Deezer find_track: jen TA skladba (stejný interpret, název i verze) -- DQ5."""

from app.catalog.deezer import _same_version


def _t(title: str, artist: str) -> dict:
    return {"title": title, "artist": {"name": artist}}


def test_studio_request_skips_live_first_hit():
    hits = [_t("Heathens (Live In Mexico City)", "Twenty One Pilots"), _t("Heathens", "Twenty One Pilots")]
    assert _same_version(hits, "twenty one pilots", "Heathens")["title"] == "Heathens"


def test_live_request_wants_live():
    hits = [_t("Heathens", "Twenty One Pilots"), _t("Heathens (Live In Mexico City)", "Twenty One Pilots")]
    assert _same_version(hits, "twenty one pilots", "Heathens (Live In Mexico City)")["title"].startswith("Heathens (Live")


def test_remaster_is_same_version():
    hits = [_t("Fisherman's Blues (2006 Remaster)", "The Waterboys")]
    assert _same_version(hits, "The Waterboys", "Fisherman's Blues") is not None


def test_other_artist_cover_rejected():
    hits = [_t("Creep", "Postmodern Jukebox"), _t("Creep (Acoustic)", "Radiohead")]
    assert _same_version(hits, "Radiohead", "Creep") is None


def test_different_song_rejected():
    hits = [_t("Car Radio", "Twenty One Pilots")]
    assert _same_version(hits, "twenty one pilots", "Ride") is None


def test_feat_and_diacritics():
    hits = [_t("Dezolát (feat. Někdo)", "Vypsaná fiXa")]
    assert _same_version(hits, "Vypsana fixa", "Dezolát") is not None
