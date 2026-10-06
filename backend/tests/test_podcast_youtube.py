"""Podcast jen na YouTube: odkaz na kanál a RSS kanálu bez klipů (Shorts)."""
from __future__ import annotations

import asyncio
import json

from app.podcasts import feeds

ATOM = b"""<?xml version="1.0" encoding="UTF-8"?>
<feed xmlns:yt="http://www.youtube.com/xml/schemas/2015" xmlns:media="http://search.yahoo.com/mrss/"
      xmlns="http://www.w3.org/2005/Atom">
 <title>CROSS-PLAY</title>
 <entry>
  <yt:videoId>AAAAAAAAAAA</yt:videoId>
  <title>Rozhovor s Ji\xc5\x99\xc3\xadm K\xc3\xa1rou</title>
  <published>2026-10-01T10:00:00+00:00</published>
  <media:group><media:description>Cel\xc3\xbd d\xc3\xadl</media:description>
   <media:thumbnail url="https://i.ytimg.com/vi/AAAAAAAAAAA/hqdefault.jpg"/></media:group>
 </entry>
 <entry>
  <yt:videoId>BBBBBBBBBBB</yt:videoId>
  <title>Kr\xc3\xa1tk\xc3\xbd klip</title>
  <published>2026-10-02T10:00:00+00:00</published>
 </entry>
</feed>"""


def test_channel_link_from_search_box():
    assert feeds.youtube_channel_link("www.youtube.com/@CROSS-PLAY-CZ") == "https://www.youtube.com/@CROSS-PLAY-CZ"
    assert feeds.youtube_channel_link("https://m.youtube.com/@CROSS-PLAY-CZ/videos") == "https://www.youtube.com/@CROSS-PLAY-CZ"
    assert feeds.youtube_channel_link("@CROSS-PLAY-CZ") == "https://www.youtube.com/@CROSS-PLAY-CZ"
    assert feeds.youtube_channel_link(
        "youtube.com/channel/UC-bzlpIyS2Indu3pKI6-lDg"
    ) == "https://www.youtube.com/channel/UC-bzlpIyS2Indu3pKI6-lDg"
    assert feeds.youtube_channel_link("vinohradská 12") is None


def test_youtube_feed_keeps_only_channel_videos_with_durations(monkeypatch):
    async def fake_yt_dlp(*args, timeout=90):
        return json.dumps({
            "channel": "CROSS-PLAY",
            "description": "Rozhovory o videohrách",
            "thumbnails": [{"id": "avatar_uncropped", "url": "https://yt3.ggpht.com/avatar", "width": 900, "height": 900}],
            "entries": [{"id": "AAAAAAAAAAA", "duration": 1860}],  # klip BBB mezi videi není
        })

    monkeypatch.setattr(feeds, "_yt_dlp", fake_yt_dlp)
    f = asyncio.run(feeds._youtube_feed(ATOM, feeds._YT_FEED + "UC-bzlpIyS2Indu3pKI6-lDg"))
    assert f["title"] == "CROSS-PLAY"
    assert f["artworkUrl"] == "https://yt3.ggpht.com/avatar"
    [ep] = f["episodes"]
    assert ep["audioUrl"] == "https://www.youtube.com/watch?v=AAAAAAAAAAA"
    assert ep["durationMs"] == 1860000
    assert ep["title"] == "Rozhovor s Jiřím Károu"
    assert feeds.youtube_video_id(ep["audioUrl"]) == "AAAAAAAAAAA"
    assert feeds.is_youtube_feed(feeds._YT_FEED + "UC-bzlpIyS2Indu3pKI6-lDg")
