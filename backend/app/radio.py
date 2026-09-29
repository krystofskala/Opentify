"""Nepřetržitý stream fronty ("rádio") pro iOS PWA.

Proč: webová appka na ploše iPhonu nesmí na zamčeném displeji spustit NOVÝ
zdroj zvuku -- po konci skladby další "hrála" potichu, dokud se appka
neotevřela (živě nahlášeno). Tady klient otevře JEDEN nekonečný MP3 stream a
server do něj skladby z fronty řadí jednu za druhou; pro Safari je to jedno
rádio, zdroj se nikdy nemění.

- Každá skladba se přes ffmpeg převede na stejný formát (MP3 44,1 kHz stereo
  CBR 192 kb/s), takže výsledek je platný souvislý MP3 proud. Korekce
  hlasitosti se aplikuje rovnou tady (na iOS jinak hlasitost nastavit nejde).
- Výstup se posílá zhruba v reálném čase s náskokem `LEAD_S` -- změny fronty
  (přidat/odebrat/přeřadit) tak stihnou ovlivnit i další skladbu.
- Když další skladba ještě není stažená, spustí se obstarání a mezitím jde
  ticho (spojení nesmí vyschnout, jinak ho iOS na zamčeném displeji zabije).
- `timeline` = kde v čase streamu která skladba začíná; klient podle
  `currentTime` pozná, co hraje, a hlásí zpět, kam došel (`played_ms`) --
  při znovupřipojení stream pokračuje odtamtud.

Relace žijí v paměti API procesu (jeden uvicorn proces) a po hodině
nečinnosti se zahodí.
"""

from __future__ import annotations

import asyncio
import logging
import time
import uuid
from dataclasses import dataclass, field

from sqlmodel import Session

from app.db import engine
from app.loudness import gain_for_client
from app.models import MediaAsset, MediaAssetStatus
from app.provisioning_service import enqueue, get_or_create_job

logger = logging.getLogger(__name__)

BITRATE_KBPS = 192
BYTES_PER_MS = BITRATE_KBPS * 1000 / 8 / 1000  # 24 B/ms
LEAD_S = 20.0  # náskok před přehráváním
CHUNK = 16 * 1024
PROVISION_WAIT_S = 180.0
SESSION_TTL_S = 3600.0


@dataclass
class Segment:
    recording_id: str
    queue_pos: int  # index v `Session.queue`
    start_ms: float  # čas ve streamu, kde skladba začíná
    offset_ms: float  # od kolika ms skladby se hraje (první skladba po seeku)
    duration_ms: float | None = None  # známé až po dopsání
    track_ms: float | None = None  # délka celé skladby (ffprobe)


@dataclass
class RadioSession:
    id: str
    user_id: str
    device_id: str | None
    queue: list[str]
    start_offset_ms: float = 0.0
    played_ms: float = 0.0  # co klient opravdu přehrál (čas streamu)
    timeline: list[Segment] = field(default_factory=list)
    connection: int = 0  # číslo posledního spojení -- starší se ukončí
    touched: float = field(default_factory=time.monotonic)


_sessions: dict[str, RadioSession] = {}


def create_session(
    user_id: str, device_id: str | None, queue: list[str], position_ms: float, session_id: str | None = None
) -> RadioSession:
    """`session_id` volí klient -- stream (`<audio src>`) tak může spustit
    hned v obsluze klepnutí a relaci založit souběžně (iOS pustí zvuk jen
    přímo po klepnutí, ne až po síťovém dotazu)."""
    _gc()
    s = RadioSession(
        id=session_id or uuid.uuid4().hex,
        user_id=user_id,
        device_id=device_id,
        queue=list(queue),
        start_offset_ms=max(0.0, position_ms),
    )
    _sessions[s.id] = s
    return s


async def wait_for_session(session_id: str, timeout_s: float = 8.0) -> RadioSession | None:
    """Stream může přijít dřív než založení relace (běží souběžně)."""
    waited = 0.0
    while waited < timeout_s:
        s = get_session(session_id)
        if s is not None:
            return s
        await asyncio.sleep(0.1)
        waited += 0.1
    return None


def get_session(session_id: str) -> RadioSession | None:
    s = _sessions.get(session_id)
    if s is not None:
        s.touched = time.monotonic()
    return s


def _gc() -> None:
    now = time.monotonic()
    for sid in [k for k, v in _sessions.items() if now - v.touched > SESSION_TTL_S]:
        _sessions.pop(sid, None)


def update_upcoming(s: RadioSession, upcoming: list[str]) -> None:
    """Klient pošle, co má hrát PO právě přehrávané skladbě. Server je ale
    s výrobou napřed (`LEAD_S`) -- skladby, které už za přehrávanou zapsal,
    se ze začátku nového seznamu vynechají, ať nehrají dvakrát; zbytek
    nahradí vše za skladbou, která se právě píše."""
    if not s.timeline:
        s.queue = s.queue[:1] + list(upcoming)
        return
    played = next((seg for seg in reversed(s.timeline) if seg.start_ms <= s.played_ms), s.timeline[0])
    written_after = [seg.recording_id for seg in s.timeline if seg.start_ms > played.start_ms]
    rest = list(upcoming)
    while written_after and rest and rest[0] == written_after[0]:
        written_after.pop(0)
        rest.pop(0)
    writing_pos = s.timeline[-1].queue_pos
    s.queue = s.queue[: writing_pos + 1] + rest


# --- výroba streamu ---------------------------------------------------------


def _asset_path_and_gain(recording_id: str) -> tuple[str | None, float | None, bool]:
    """(cesta, korekce dB, je_ve_stavu_obstaravani)."""
    with Session(engine) as db:
        asset = db.get(MediaAsset, recording_id)
        if asset is not None and asset.status == MediaAssetStatus.AVAILABLE and asset.storage_path:
            return asset.storage_path, gain_for_client(asset.loudness_gain_db), False
        failed = asset is not None and asset.status == MediaAssetStatus.FAILED
        return None, None, not failed


async def _request_provision(s: RadioSession, recording_id: str) -> None:
    try:
        with Session(engine) as db:
            _asset, job, created = get_or_create_job(db, recording_id, s.user_id, s.device_id)
        if job is not None and created:
            await enqueue(job, interactive=True)
    except Exception as exc:  # noqa: BLE001 -- best effort, stream jede dál
        logger.warning("rádio: obstarání %s selhalo: %s", recording_id, exc)


_SILENCE_FRAME: bytes | None = None


async def _silence(ms: float) -> bytes:
    """Ticho ve stejném MP3 formátu (vygenerované jednou přes ffmpeg)."""
    global _SILENCE_FRAME
    if _SILENCE_FRAME is None:
        proc = await asyncio.create_subprocess_exec(
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i", "anullsrc=r=44100:cl=stereo",
            "-t", "1", "-c:a", "libmp3lame", "-b:a", f"{BITRATE_KBPS}k", "-write_xing", "0", "-id3v2_version", "0",
            "-f", "mp3", "-",
            stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL,
        )
        out, _ = await proc.communicate()
        _SILENCE_FRAME = out or b""
    if not _SILENCE_FRAME:
        return b""
    reps = max(1, int(ms // 1000))
    return _SILENCE_FRAME * reps


def _probe_ms(path: str) -> float | None:
    import subprocess

    try:
        out = subprocess.run(
            ["ffprobe", "-v", "error", "-show_entries", "format=duration", "-of", "default=nw=1:nk=1", path],
            capture_output=True, text=True, timeout=15,
        ).stdout.strip()
        return float(out) * 1000 if out else None
    except (OSError, ValueError, subprocess.TimeoutExpired):
        return None


def _ffmpeg_cmd(path: str, offset_ms: float, gain_db: float | None) -> list[str]:
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
    if offset_ms > 0:
        cmd += ["-ss", f"{offset_ms / 1000:.3f}"]
    cmd += ["-i", path, "-vn", "-sn", "-dn", "-ac", "2", "-ar", "44100"]
    if gain_db:
        cmd += ["-af", f"volume={gain_db:.2f}dB"]
    cmd += ["-c:a", "libmp3lame", "-b:a", f"{BITRATE_KBPS}k", "-write_xing", "0", "-id3v2_version", "0", "-f", "mp3", "-"]
    return cmd


async def stream(s: RadioSession):
    """Async generátor bajtů jednoho spojení. Nové spojení (Safari se občas
    připojí znovu) začne od skladby, kterou klient naposledy hlásil jako
    přehrávanou, a to staré se ukončí."""
    s.connection += 1
    me = s.connection
    # Kde pokračovat: segment, ve kterém je `played_ms` (po znovupřipojení).
    start_pos, offset = 0, s.start_offset_ms
    for seg in reversed(s.timeline):
        if seg.start_ms <= s.played_ms:
            start_pos = seg.queue_pos
            offset = seg.offset_ms + (s.played_ms - seg.start_ms)
            break
    s.timeline = []
    # Čas streamu navazuje tam, kam klient došel -- jeho `currentTime` po
    # znovupřipojení běží dál, ne od nuly.
    base_ms = s.played_ms
    written_ms = base_ms
    started = time.monotonic()

    async def pace() -> None:
        # Drž náskok max `LEAD_S` před reálným časem od začátku spojení.
        ahead = (written_ms - base_ms) / 1000 - (time.monotonic() - started)
        if ahead > LEAD_S:
            await asyncio.sleep(ahead - LEAD_S)

    pos = start_pos
    while pos < len(s.queue):
        if s.connection != me:
            return
        rid = s.queue[pos]
        # Další skladbu obstarat dopředu (dokud tahle hraje).
        if pos + 1 < len(s.queue):
            nxt = s.queue[pos + 1]
            path_n, _g, pending_n = await asyncio.to_thread(_asset_path_and_gain, nxt)
            if path_n is None and pending_n:
                asyncio.create_task(_request_provision(s, nxt))

        path, gain, pending = await asyncio.to_thread(_asset_path_and_gain, rid)
        if path is None and pending:
            await _request_provision(s, rid)
            waited = 0.0
            while path is None and pending and waited < PROVISION_WAIT_S:
                chunk = await _silence(1000)
                written_ms += 1000
                yield chunk
                await pace()
                waited += 1.0
                if s.connection != me:
                    return
                path, gain, pending = await asyncio.to_thread(_asset_path_and_gain, rid)
        if path is None:
            logger.info("rádio: %s nejde přehrát, přeskakuji", rid)
            pos += 1
            offset = 0.0
            continue

        seg = Segment(
            recording_id=rid,
            queue_pos=pos,
            start_ms=written_ms,
            offset_ms=offset,
            track_ms=await asyncio.to_thread(_probe_ms, path),
        )
        s.timeline.append(seg)
        proc = await asyncio.create_subprocess_exec(
            *_ffmpeg_cmd(path, offset, gain), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
        )
        seg_bytes = 0
        try:
            assert proc.stdout is not None
            while True:
                if s.connection != me:
                    return
                data = await proc.stdout.read(CHUNK)
                if not data:
                    break
                seg_bytes += len(data)
                written_ms += len(data) / BYTES_PER_MS
                yield data
                await pace()
        finally:
            if proc.returncode is None:
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
            await proc.wait()
        seg.duration_ms = seg_bytes / BYTES_PER_MS
        pos += 1
        offset = 0.0
