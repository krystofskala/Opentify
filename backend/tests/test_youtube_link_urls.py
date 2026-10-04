"""Rozpoznání odkazů na YouTube (živě: playlist z YouTube Music "nevypadá
jako odkaz na YouTube")."""
import pytest

from app.library.youtube_link import YoutubeLinkError, _normalized_url


@pytest.mark.parametrize(
    ("text", "expected"),
    [
        ("https://music.youtube.com/playlist?list=RDCLAK5uy_kAbCdEfGh123&si=xyz",
         "https://www.youtube.com/playlist?list=RDCLAK5uy_kAbCdEfGh123"),
        ("https://youtube.com/playlist?list=PLabc123&si=Qq", "https://www.youtube.com/playlist?list=PLabc123"),
        ("https://music.youtube.com/playlist?list=OLAK5uy_xyz", "https://www.youtube.com/playlist?list=OLAK5uy_xyz"),
        # Automatický mix k videu -> to video, ne mix.
        ("https://www.youtube.com/watch?v=dQw4w9WgXcQ&list=RDdQw4w9WgXcQ", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
        ("https://www.youtube.com/playlist?list=RDMMabc", "https://www.youtube.com/playlist?list=RDMMabc"),
        ("https://music.youtube.com/browse/MPREb_AbCdEf123", "https://music.youtube.com/browse/MPREb_AbCdEf123"),
        ("Koukni https://youtu.be/dQw4w9WgXcQ?si=a", "https://www.youtube.com/watch?v=dQw4w9WgXcQ"),
    ],
)
def test_normalized_url(text, expected):
    assert _normalized_url(text) == expected


def test_not_a_link():
    with pytest.raises(YoutubeLinkError):
        _normalized_url("https://www.youtube.com/@kanal")
