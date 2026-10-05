"""Export z Apple Music: ZIP ve ZIPu, Play Activity bez interpreta --
interpret z knihovny, z "Interpret - Skladba" přehledů a podle alba;
citlivé sloupce (IP, poloha) se nikam nedostanou."""
import csv
import io
import json
import zipfile

from app.library import apple_history as ah

_HEAD = ["Event Type", "Song Name", "Album Name", "Event Start Timestamp", "Event Timestamp",
         "Play Duration Milliseconds", "End Reason Type", "Media Type", "Client IP Address", "IP City"]


def _row(song, album, ms=200_000, reason="NATURAL_END_OF_TRACK", event="PLAY_END", media="AUDIO"):
    return [event, song, album, "2026-07-27T16:22:02.723Z", "2026-07-27T16:25:45.010Z", str(ms), reason, media,
            "10.0.0.1", "PRAGUE"]


def _csv(head, rows):
    buf = io.StringIO()
    w = csv.writer(buf)
    w.writerow(head)
    w.writerows(rows)
    return buf.getvalue().encode("utf-8")


def _export(rows):
    library = [{"Title": "Into the Sun", "Artist": "Sons of Kemet", "Album": "Your Queen Is a Reptile"},
               {"Title": "Taxman", "Artist": "The Beatles", "Album": "Revolver (Super Deluxe)"}]
    inner = io.BytesIO()
    with zipfile.ZipFile(inner, "w") as zf:
        base = "Apple_Media_Services/Apple Music Activity/"
        zf.writestr(base + "Apple Music Play Activity.csv", _csv(_HEAD, rows))
        zf.writestr(base + "Apple Music - Track Play History.csv",
                    _csv(["Track Name", "Last Played Date", "Is User Initiated"], [["The Band - The Weight", "1", "true"]]))
        lib = io.BytesIO()
        with zipfile.ZipFile(lib, "w") as lz:
            lz.writestr("Apple Music Library Tracks.json", json.dumps(library))
        zf.writestr(base + "Apple Music Library Tracks.json.zip", lib.getvalue())
    outer = io.BytesIO()
    with zipfile.ZipFile(outer, "w") as zf:
        zf.writestr("Informace Část 1 z 2/Apple_Media_Services.zip", inner.getvalue())
    return outer.getvalue()


def test_reads_nested_export_and_resolves_artists():
    result = ah.read_export(_export([
        _row("Into the Sun", "Your Queen Is a Reptile"),          # knihovna (skladba + album)
        _row("The Weight", ""),                                   # "Interpret - Skladba"
        _row("Good Day Sunshine", "Revolver (Super Deluxe)"),     # jiná skladba téhož alba
        _row("Nobody Knows", "Unknown Album"),                    # nic -> bez interpreta
        _row("Into the Sun", "Your Queen Is a Reptile", event="PLAY_START"),
        _row("Some Video", "", media="VIDEO"),
    ]))
    assert result.is_apple
    artists = {p["track"]: p["artist"] for p in result.plays}
    assert artists == {"Into the Sun": "Sons of Kemet", "The Weight": "The Band",
                       "Good Day Sunshine": "The Beatles", "Nobody Knows": None}
    assert len(result.library) == 2
    play = result.plays[0]
    assert play["ts"] == "2026-07-27T16:25:45.010000Z" and play["ms"] == 200_000
    assert play["reason_end"] == "trackdone"
    assert not any("10.0.0.1" in json.dumps(p) or "PRAGUE" in json.dumps(p) for p in result.plays)


def test_skips_map_to_spotify_vocabulary():
    from app.library.spotify_history import _end_reason

    result = ah.read_export(_export([
        _row("Into the Sun", "Your Queen Is a Reptile", ms=5_000, reason="TRACK_SKIPPED_FORWARDS"),
        _row("Into the Sun", "Your Queen Is a Reptile", ms=90_000, reason="PLAYBACK_MANUALLY_PAUSED"),
    ]))
    assert [_end_reason(p) for p in result.plays] == ["skipped", "stopped"]


def test_unresolved_plays_wait_and_resolve_later(monkeypatch):
    """Bez interpreta se nic nezahodí: čeká v PendingImportPlay, pozadí ho
    dohledá (tady katalog), nenalezené zkusí znovu později."""
    import asyncio
    import uuid

    from sqlmodel import Session, select

    from app.db import engine
    from app.library import pending_plays as pp
    from app.library.matching import find_or_create_artist, find_or_create_release
    from app.models import Listen, PendingImportPlay

    run = uuid.uuid4().hex[:8]
    user, album = "apple-" + run, "Live At the Regal " + run
    monkeypatch.setattr(pp, "lookup_itunes", lambda *a: asyncio.sleep(0, result=None))
    play = {"ts": "2026-07-27T16:25:45Z", "ms": 200_000, "reason_end": "trackdone"}
    pp.save_pending(user, "applemusic-history", [
        dict(play, track="Help the Poor", album=album),
        dict(play, track="Nobody Knows " + run, album=None),
    ])
    with Session(engine) as s:  # album se mezitím objeví v katalogu
        find_or_create_release(s, find_or_create_artist(s, "B.B. King " + run), album)
    assert asyncio.run(pp.resolve_pending(pause=0)) >= 1
    with Session(engine) as s:
        listens = s.exec(select(Listen).where(Listen.user_id == user)).all()
        waiting = s.exec(select(PendingImportPlay).where(PendingImportPlay.user_id == user)).all()
    assert len(listens) == 1 and listens[0].source == "applemusic-history"
    assert [w.track for w in waiting] == ["Nobody Knows " + run] and waiting[0].attempts == 1
    assert asyncio.run(pp.resolve_pending(pause=0)) == 0  # ještě není na řadě


def test_itunes_match_ignores_suffixes(monkeypatch):
    import asyncio

    from app.library import pending_plays as pp

    items = [
        {"artistName": "Johnny Defrancesco", "trackName": "Help the Poor (feat. Duke Jethro) [Live]",
         "collectionName": "Tribute to B. B. King's \"Live at the Regal\""},
        {"artistName": "B.B. King", "trackName": "Help the Poor (Live At The Regal Theater/1964)",
         "collectionName": "Live At the Regal"},
    ]

    class Resp:
        status_code = 200

        def json(self):
            return {"results": items}

    class Client:
        async def get(self, *a, **k):
            return Resp()

    import app.apple_http as ah_http
    monkeypatch.setattr(ah_http, "apple_http", lambda: Client())
    assert asyncio.run(pp.lookup_itunes("Help the Poor", "Live At the Regal")) == "B.B. King"
    assert asyncio.run(pp.lookup_itunes("Help the Poor", "Nějaké jiné album")) is None


def test_not_apple():
    assert not ah.read_export(b"not a zip").is_apple
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w") as zf:
        zf.writestr("Playlist1.json", "{}")
    assert not ah.read_export(buf.getvalue()).is_apple
