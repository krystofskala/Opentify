"""fanart.tv výběr banneru/fotky -- bez sítě a bez klíče, na nahrané ukázce
odpovědi `GET /v3/music/{mbid}` (zkrácené, struktura podle webservice.fanart.tv).

Spuštění v kontejneru:  python -m tests.test_fanart   (nebo pytest)
"""

from __future__ import annotations

import asyncio
import os
from unittest import mock

from app.catalog import fanart

SAMPLE = {
    "name": "Radiohead",
    "mbid_id": "a74b1b7f-71a5-4011-9441-d0b5e4122711",
    "artistbackground": [
        {"id": "1", "url": "https://assets.fanart.tv/fanart/music/a74b/artistbackground/radiohead-low.jpg", "likes": "2"},
        {"id": "2", "url": "https://assets.fanart.tv/fanart/music/a74b/artistbackground/radiohead-best.jpg", "likes": "11"},
    ],
    "artistthumb": [
        {"id": "3", "url": "https://assets.fanart.tv/fanart/music/a74b/artistthumb/radiohead-thumb.jpg", "likes": "5"},
    ],
    "hdmusiclogo": [{"id": "4", "url": "https://assets.fanart.tv/fanart/music/a74b/hdmusiclogo/radiohead.png", "likes": "3"}],
}


def test_pick_banner_and_thumb_prefers_most_liked() -> None:
    banner, thumb = fanart.pick_banner_and_thumb(SAMPLE)
    assert banner and banner.endswith("radiohead-best.jpg")
    assert thumb and thumb.endswith("radiohead-thumb.jpg")


def test_pick_handles_missing_sections() -> None:
    assert fanart.pick_banner_and_thumb({}) == (None, None)
    assert fanart.pick_banner_and_thumb(None) == (None, None)
    assert fanart.pick_banner_and_thumb({"artistthumb": SAMPLE["artistthumb"]})[0] is None


def test_no_key_means_no_network() -> None:
    with mock.patch.dict(os.environ, {"FANART_API_KEY": ""}):
        assert asyncio.run(fanart.fetch_artist_art("any")) is None
        assert asyncio.run(fanart.fill_artist_banner("any")) is False


if __name__ == "__main__":
    test_pick_banner_and_thumb_prefers_most_liked()
    test_pick_handles_missing_sections()
    test_no_key_means_no_network()
    print("fanart tests: OK")
