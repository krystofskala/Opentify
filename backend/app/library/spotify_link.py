"""Import z odkazu na Spotify (playlist, album, skladba) -- bez účtu a klíče.

Spotify ukazuje obsah veřejného playlistu/alba komukoliv na stránce pro
vložení (`open.spotify.com/embed/<druh>/<id>`); v ní je JSON `__NEXT_DATA__`
s názvem, autorem, obalem a skladbami (název, interpreti, délka). Stránka
dává nejvýš prvních 100 skladeb -- zbytek by chtěl Spotify účet a klíč
vývojáře, takže delší playlist se naimportuje zkrácený a klient to řekne.

Soukromí: stahuje se VÝHRADNĚ přes Mullvad VPN (`SPOTIFY_PROXY`, výchozí
stejná proxy jako Open Shazam); bez proxy se import odmítne -- Spotify
nemá vidět domácí IP. Matchování na katalog stejně jako import exportu
(`spotify_import._import_tracks_into_playlist`), playlist se zrcadlí
(opakovaný import stejného odkazu nahradí obsah, nevznikne duplikát).
"""

from __future__ import annotations

import json
import os
import re
from dataclasses import dataclass

import httpx
from sqlmodel import Session

from app.catalog.embedded_art import URL_TEMPLATE, _save_resized, artwork_path
from app.library.matching import find_or_create_artist, find_or_create_recording
from app.library.spotify_import import PlaylistReport, TrackRow, _get_or_create_playlist, _import_tracks_into_playlist

EMBED_LIMIT = 100
_SOURCE_PREFIX = "spotify-link:"
_URL = re.compile(
    r"(?:open\.spotify\.com/(?:intl-[a-z]{2}/)?(?:embed/)?|spotify:)(playlist|album|track)[/:]([A-Za-z0-9]{22})"
)
_UA = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/140 Safari/537.36"


class SpotifyLinkError(Exception):
    """Chyba s českou zprávou pro uživatele."""


@dataclass
class SpotifyLinkResult:
    report: PlaylistReport | None
    kind: str
    truncated: bool
    owner: str | None
    # Odkaz na jednu skladbu: žádný playlist, jen skladba k přehrání.
    recording_id: str | None = None


def _proxy() -> str:
    value = os.environ.get("SPOTIFY_PROXY") or os.environ.get("SHAZAM_PROXY", "http://gluetun:8888")
    value = value.strip()
    if not value:
        raise SpotifyLinkError("Import ze Spotify je vypnutý: chybí VPN proxy.")
    return value


def parse_spotify_url(text: str) -> tuple[str, str] | None:
    """(druh, id) z odkazu `open.spotify.com/...` nebo URI `spotify:...`."""
    m = _URL.search(text or "")
    return (m.group(1), m.group(2)) if m else None


async def _resolve_short_link(client: httpx.AsyncClient, text: str) -> str:
    # `spotify.link/xyz` (sdílení z mobilní appky) přesměruje na open.spotify.com.
    m = re.search(r"https?://spotify\.link/[A-Za-z0-9]+", text or "")
    if not m:
        return text
    resp = await client.get(m.group(0), follow_redirects=True)
    return str(resp.url)


def _primary_artist(subtitle: str | None) -> str:
    # "YUNGBLUD, mgk" (s nezlomitelnou mezerou) -> hlavní interpret.
    return (subtitle or "").replace("\xa0", " ").split(",")[0].strip()


async def fetch_spotify_link(text: str) -> tuple[str, str, str, str | None, list[TrackRow], bytes | None]:
    """-> (druh, id, název, autor, skladby, obal). Obal stahuje server (přes
    VPN) a appka ho pak načítá jen od nás -- Spotify nevidí telefon."""
    async with httpx.AsyncClient(proxy=_proxy(), timeout=30, headers={"User-Agent": _UA, "Accept-Language": "en"}) as client:
        text = await _resolve_short_link(client, text)
        parsed = parse_spotify_url(text)
        if parsed is None:
            raise SpotifyLinkError("Tohle nevypadá jako odkaz na Spotify playlist, album nebo skladbu.")
        kind, sid = parsed
        resp = await client.get(f"https://open.spotify.com/embed/{kind}/{sid}")
        if resp.status_code == 404:
            raise SpotifyLinkError("Spotify tenhle obsah nenašel -- možná je soukromý nebo smazaný.")
        resp.raise_for_status()
        cover: bytes | None = None
        cover_match = re.search(r'"coverArt":\{"sources":\[\{[^}]*"url":"([^"]+)"', resp.text)
        if cover_match:
            try:
                img = await client.get(cover_match.group(1))
                if img.status_code == 200 and len(img.content) < 5 * 1024 * 1024:
                    cover = img.content
            except httpx.HTTPError:
                cover = None  # obal je jen bonus
    m = re.search(r'<script id="__NEXT_DATA__" type="application/json">(.*?)</script>', resp.text, re.S)
    if not m:
        raise SpotifyLinkError("Spotify vrátil nečekanou stránku, zkus to později.")
    try:
        entity = json.loads(m.group(1))["props"]["pageProps"]["state"]["data"]["entity"]
    except (KeyError, TypeError, json.JSONDecodeError) as exc:
        raise SpotifyLinkError("Spotify vrátil nečekanou stránku, zkus to později.") from exc
    name = (entity.get("name") or entity.get("title") or "Spotify").strip()
    owner = (entity.get("subtitle") or "").replace("\xa0", " ").strip() or None
    if kind == "track":
        rows: list[TrackRow] = [(_primary_artist(entity.get("subtitle")), name, None, entity.get("duration"))]
    else:
        album = name if kind == "album" else None
        rows = [
            (_primary_artist(t.get("subtitle")), (t.get("title") or "").strip(), album, t.get("duration"))
            for t in entity.get("trackList") or []
        ]
    return kind, sid, name, owner, rows, cover


async def import_spotify_link(session: Session, user_id: str, text: str) -> SpotifyLinkResult:
    """Odkaz na Spotify NEBO Apple Music (app/library/apple_link.py)."""
    from app.library.apple_link import fetch_apple_link, is_apple_music_url

    if is_apple_music_url(text):
        try:
            kind, sid, name, owner, rows, cover = await fetch_apple_link(text, _proxy())
        except ValueError as exc:
            raise SpotifyLinkError(str(exc)) from exc
        prefix, origin = "apple-link:", "Z Apple Music"
    else:
        kind, sid, name, owner, rows, cover = await fetch_spotify_link(text)
        prefix, origin = _SOURCE_PREFIX, "Ze Spotify"
    if not rows:
        raise SpotifyLinkError("V odkazu nejsou žádné skladby.")
    if kind == "track":
        # Jedna skladba se jen pustí -- do Knihovny › Sdílené nepatří.
        artist_name, track_name, _album, duration_ms = rows[0]
        artist = find_or_create_artist(session, artist_name)
        recording = find_or_create_recording(session, artist, track_name, duration_ms=duration_ms)
        session.commit()
        return SpotifyLinkResult(report=None, kind=kind, truncated=False, owner=owner, recording_id=recording.id)
    playlist = _get_or_create_playlist(session, user_id, f"{prefix}{kind}:{sid}", name)
    # Autor ("Ze Spotify · Jméno") a obal pro záložku Sdílené v Knihovně.
    playlist.description = f"{origin} · {owner}" if owner else origin
    if cover and _save_resized(cover, artwork_path(playlist.id)):
        playlist.cover_urls = [URL_TEMPLATE.format(release_id=playlist.id)]
    session.add(playlist)
    session.commit()
    report = _import_tracks_into_playlist(session, playlist, rows, mirror=True)
    return SpotifyLinkResult(
        report=report,
        kind=kind,
        truncated=prefix == _SOURCE_PREFIX and kind == "playlist" and len(rows) >= EMBED_LIMIT,
        owner=owner,
    )
