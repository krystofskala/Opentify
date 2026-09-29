"""Open Shazam: rozpoznání skladby z krátké nahrávky mikrofonu.

Soukromí (uživatel chtěl anonymní řešení):
  - nahrávka jde jen na tenhle server a po rozpoznání se zahodí (dočasný
    soubor), nikam se neukládá;
  - ze zvuku se tady spočítá otisk (Shazam signature, knihovna shazamio) a
    Shazamu jde JEN otisk -- ne zvuk, ne účet, ne údaje o telefonu; každý
    dotaz nese nové náhodné identifikátory;
  - dotaz jde přes Mullvad VPN (`SHAZAM_PROXY`, výchozí gluetun). Bez proxy
    se rozpoznávání odmítne, nikdy nejde z domácí IP. Gluetun má kill
    switch -- když VPN spadne, dotaz neprojde vůbec.

Knihovna je neoficiální (zpětně rozluštěný protokol Shazamu) -- jednou se
může rozbít; chyby se hlásí jako 502, ne jako "nic nenalezeno".
"""

from __future__ import annotations

import asyncio
import os
import tempfile
from dataclasses import dataclass
from typing import Any

MAX_UPLOAD_BYTES = 4 * 1024 * 1024
MAX_SECONDS = 20


class RecognizeError(Exception):
    pass


@dataclass
class Match:
    title: str
    artist: str
    album: str | None
    isrc: str | None
    cover_url: str | None
    shazam_key: str | None


def _proxy() -> str | None:
    value = os.environ.get("SHAZAM_PROXY", "http://gluetun:8888").strip()
    return value or None


async def _to_wav(raw: bytes) -> bytes:
    # Do souboru, ne rourou: MP4 z iOS MediaRecorderu nemusí mít hlavičku na
    # začátku a ffmpeg ho z roury nepřečte.
    with tempfile.NamedTemporaryFile(suffix=".bin") as src:
        src.write(raw)
        src.flush()
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-v", "error", "-i", src.name, "-t", str(MAX_SECONDS),
            "-ac", "1", "-ar", "16000", "-f", "wav", "pipe:1",
            stdout=asyncio.subprocess.PIPE,
            stderr=asyncio.subprocess.PIPE,
        )
        wav, err = await asyncio.wait_for(proc.communicate(), timeout=30)
    if proc.returncode != 0 or len(wav) < 16000:
        raise RecognizeError(f"nahrávku se nepodařilo dekódovat: {err.decode(errors='replace')[:200]}")
    return wav


def _parse(result: dict[str, Any]) -> Match | None:
    track = result.get("track") or {}
    title = (track.get("title") or "").strip()
    artist = (track.get("subtitle") or "").strip()
    if not title or not artist:
        return None
    album = None
    for section in track.get("sections") or []:
        for meta in section.get("metadata") or []:
            if (meta.get("title") or "").lower() in ("album", "album:") and meta.get("text"):
                album = meta["text"].strip()
    images = track.get("images") or {}
    return Match(
        title=title,
        artist=artist,
        album=album,
        isrc=track.get("isrc"),
        cover_url=images.get("coverarthq") or images.get("coverart"),
        shazam_key=track.get("key"),
    )


async def recognize(raw: bytes) -> Match | None:
    """`None` = zvuk v pořádku, ale Shazam skladbu nezná / neslyšel."""
    if len(raw) > MAX_UPLOAD_BYTES:
        raise RecognizeError("nahrávka je moc velká")
    proxy = _proxy()
    if proxy is None:
        raise RecognizeError("rozpoznávání je vypnuté: chybí VPN proxy (SHAZAM_PROXY)")
    from shazamio import Shazam

    wav = await _to_wav(raw)
    try:
        result = await asyncio.wait_for(Shazam(language="cs-CZ", endpoint_country="CZ").recognize(data=wav, proxy=proxy), timeout=25)
    except Exception as exc:  # noqa: BLE001 - síť/VPN/změna protokolu
        raise RecognizeError(f"Shazam neodpověděl: {type(exc).__name__}") from exc
    return _parse(result)


async def fetch_cover(url: str | None) -> bytes | None:
    """Obal z Shazamu (Apple CDN) stáhne server -- taky přes VPN -- a uloží
    ho k sobě; telefon ho pak načítá jen z vlastního serveru."""
    proxy = _proxy()
    if not url or proxy is None:
        return None
    import httpx

    try:
        async with httpx.AsyncClient(proxy=proxy, timeout=15, follow_redirects=True) as client:
            response = await client.get(url.replace("400x400", "1000x1000"))
            response.raise_for_status()
            return response.content if len(response.content) < 5 * 1024 * 1024 else None
    except Exception:  # noqa: BLE001 - obal je jen bonus
        return None
