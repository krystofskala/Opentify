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
import os
import shutil
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path

from sqlmodel import Session

from app.db import engine
from app.loudness import gain_for_client
from app.models import MediaAsset, MediaAssetStatus
from app.provisioning_service import enqueue, get_or_create_job

# Logger uvicornu -- úroveň INFO je v logu kontejneru vidět (diagnostika spojení).
logger = logging.getLogger("uvicorn.error")

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
    connection: int = 0  # počítadlo spojení
    owner: int = 0  # spojení, které vlastní časovou osu
    touched: float = field(default_factory=time.monotonic)
    hls_task: asyncio.Task | None = None
    hls_touched: float = field(default_factory=time.monotonic)  # poslední stažení playlistu/úseku
    hls_done: bool = False
    # A-B opakování: úsek první skladby se řadí pořád dokola (plynulá smyčka
    # bez nového streamu při každém opakování).
    ab_start_ms: float | None = None
    ab_end_ms: float | None = None


_sessions: dict[str, RadioSession] = {}


def create_session(
    user_id: str,
    device_id: str | None,
    queue: list[str],
    position_ms: float,
    session_id: str | None = None,
    ab: tuple[float, float] | None = None,
) -> RadioSession:
    """`session_id` volí klient -- stream (`<audio src>`) tak může spustit
    hned v obsluze klepnutí a relaci založit souběžně (iOS pustí zvuk jen
    přímo po klepnutí, ne až po síťovém dotazu)."""
    _gc()
    old = _sessions.get(session_id or "")
    if old is not None:
        _stop(old)
    s = RadioSession(
        id=session_id or uuid.uuid4().hex,
        user_id=user_id,
        device_id=device_id,
        queue=list(queue),
        start_offset_ms=max(0.0, position_ms),
    )
    if ab is not None and ab[1] - ab[0] >= 1000:
        s.ab_start_ms, s.ab_end_ms = ab
    _sessions[s.id] = s
    s.hls_task = asyncio.get_running_loop().create_task(_run_hls(s))
    return s


def _stop(s: RadioSession) -> None:
    if s.hls_task is not None and not s.hls_task.done():
        s.hls_task.cancel()
    shutil.rmtree(RADIO_DIR / s.id, ignore_errors=True)


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
        s = _sessions.pop(sid, None)
        if s is not None:
            _stop(s)


# --- HLS (iOS) --------------------------------------------------------------
#
# Obyčejný MP3 stream v <audio> stahuje Safari ve webové stránce -- iOS jí po
# odchodu z appky síť uspí; spojení zavřel po 4 s, dohrál ~20 s zásobníku a
# zastavil (živě v logu). HLS v Safari stahuje systémový přehrávač
# (AVPlayer), který běží i na pozadí a se zamčeným displejem -- stejně jako
# Apple Music nebo internetová rádia. Jeden výrobce na relaci převádí souvislý
# MP3 proud z `_produce` na HLS (AAC v MPEG-TS, 4s úseky, playlist typu EVENT,
# který průběžně roste). Čas HLS = čas MP3 proudu, časová osa platí dál.

RADIO_DIR = Path(os.environ.get("RADIO_TMP", "/tmp/opentify-radio"))
HLS_SEGMENT_S = 4
HLS_IDLE_STOP_S = 300.0  # nikdo nestahuje 5 min -> výroba se zastaví


async def _run_hls(s: RadioSession) -> None:
    d = RADIO_DIR / s.id
    d.mkdir(parents=True, exist_ok=True)
    proc = await asyncio.create_subprocess_exec(
        "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "mp3", "-i", "pipe:0",
        "-c:a", "aac", "-b:a", "192k", "-ar", "44100", "-ac", "2",
        "-f", "hls", "-hls_time", str(HLS_SEGMENT_S), "-hls_list_size", "0", "-hls_playlist_type", "event",
        "-hls_segment_filename", str(d / "seg%05d.ts"), str(d / "index.m3u8"),
        stdin=asyncio.subprocess.PIPE, stdout=asyncio.subprocess.DEVNULL, stderr=asyncio.subprocess.DEVNULL,
    )
    timeline: list[Segment] = []
    s.timeline = timeline
    started = time.monotonic()
    logger.info("rádio %s HLS start", s.id[:6])
    try:
        assert proc.stdin is not None
        async for data, written_ms in _produce(s, 0, s.start_offset_ms, 0.0, timeline):
            proc.stdin.write(data)
            await proc.stdin.drain()
            ahead = written_ms / 1000 - (time.monotonic() - started)
            if ahead > LEAD_S:
                await asyncio.sleep(ahead - LEAD_S)
            if time.monotonic() - s.hls_touched > HLS_IDLE_STOP_S:
                logger.info("rádio %s HLS: nikdo neposlouchá, končím", s.id[:6])
                break
        proc.stdin.close()
        await proc.wait()
        s.hls_done = True
        logger.info("rádio %s HLS konec (%.0f s)", s.id[:6], time.monotonic() - started)
    except asyncio.CancelledError:
        logger.info("rádio %s HLS zrušeno", s.id[:6])
        raise
    except Exception as exc:  # noqa: BLE001
        logger.warning("rádio %s HLS chyba: %s", s.id[:6], exc)
    finally:
        if proc.returncode is None:
            try:
                proc.kill()
            except ProcessLookupError:
                pass
            await proc.wait()


async def hls_playlist(s: RadioSession, wait_s: float = 15.0) -> str | None:
    """Playlist s `EXT-X-START` na začátek -- jinak by Safari u "živého"
    playlistu začal až u konce (live edge) a přeskočil začátek skladby."""
    s.hls_touched = time.monotonic()
    path = RADIO_DIR / s.id / "index.m3u8"
    waited = 0.0
    while waited < wait_s:
        if path.exists():
            text = path.read_text()
            if "#EXTINF" in text:
                lines = text.splitlines()
                out = []
                for line in lines:
                    out.append(line)
                    if line.startswith("#EXT-X-VERSION") or (line == "#EXTM3U" and not any(
                        l.startswith("#EXT-X-VERSION") for l in lines
                    )):
                        out.append("#EXT-X-START:TIME-OFFSET=0,PRECISE=YES")
                return "\n".join(out) + "\n"
        await asyncio.sleep(0.25)
        waited += 0.25
    return None


def hls_segment_path(s: RadioSession, name: str) -> Path | None:
    s.hls_touched = time.monotonic()
    path = RADIO_DIR / s.id / name
    return path if path.is_file() else None


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


def _ffmpeg_cmd(path: str, offset_ms: float, gain_db: float | None, length_ms: float | None = None) -> list[str]:
    cmd = ["ffmpeg", "-hide_banner", "-loglevel", "error", "-nostdin"]
    if offset_ms > 0:
        cmd += ["-ss", f"{offset_ms / 1000:.3f}"]
    if length_ms is not None:
        cmd += ["-t", f"{length_ms / 1000:.3f}"]
    cmd += ["-i", path, "-vn", "-sn", "-dn", "-ac", "2", "-ar", "44100"]
    if gain_db:
        cmd += ["-af", f"volume={gain_db:.2f}dB"]
    cmd += ["-c:a", "libmp3lame", "-b:a", f"{BITRATE_KBPS}k", "-write_xing", "0", "-id3v2_version", "0", "-f", "mp3", "-"]
    return cmd


_OWNER_AFTER_BYTES = 64 * 1024


def _locate(s: RadioSession, target_ms: float) -> tuple[int, float, float]:
    """Kde ve frontě je čas streamu `target_ms` -> (pozice, offset ve skladbě,
    čas streamu, od kterého se začne psát)."""
    for seg in reversed(s.timeline):
        if seg.start_ms <= target_ms:
            if seg.duration_ms is not None and target_ms >= seg.start_ms + seg.duration_ms:
                return seg.queue_pos + 1, 0.0, seg.start_ms + seg.duration_ms
            return seg.queue_pos, seg.offset_ms + (target_ms - seg.start_ms), target_ms
    return 0, s.start_offset_ms, 0.0


async def stream(s: RadioSession, start_byte: int = 0, label: str = ""):
    """Async generátor bajtů jednoho spojení.

    Spojení se navzájem NERUŠÍ -- Safari otevírá víc spojení (zkušební dotaz,
    znovupřipojení při odchodu z appky) a dřívější verze při každém novém
    spojení ukončila to předchozí; když z něj Safari zrovna přehrával, zvuk
    dohrál zásobník a zastavil se uprostřed skladby (živě nahlášeno).

    Stream je deterministický podle času: `start_byte` (Range od Safari) se
    přepočte na čas streamu (CBR) a pokračuje se odtamtud -- navazuje tak
    přesně na to, co už Safari má. Časovou osu pro klienta vlastní nejnovější
    spojení, které už opravdu streamuje (> 64 kB), ne krátké zkušební dotazy.
    """
    s.connection += 1
    me = s.connection
    local_timeline: list[Segment] = []
    target_ms = start_byte / BYTES_PER_MS
    pos, offset, written_ms = _locate(s, target_ms) if start_byte > 0 else (0, s.start_offset_ms, 0.0)
    if start_byte > 0:
        # Segmenty před místem navázání zůstávají platné.
        local_timeline = [seg for seg in s.timeline if seg.start_ms < written_ms]
    conn_start_ms = written_ms
    started = time.monotonic()
    sent = 0
    logger.info("rádio %s spojení #%d start (byte %d -> %.1f s) %s", s.id[:6], me, start_byte, written_ms / 1000, label)

    def publish() -> None:
        # Nejnovější skutečně streamující spojení vlastní časovou osu.
        if sent >= _OWNER_AFTER_BYTES and me >= s.owner:
            s.owner = me
            s.timeline = local_timeline

    async def pace() -> None:
        # Drž náskok max `LEAD_S` před reálným časem od začátku spojení.
        ahead = (written_ms - conn_start_ms) / 1000 - (time.monotonic() - started)
        if ahead > LEAD_S:
            await asyncio.sleep(ahead - LEAD_S)

    try:
        async for chunk_info in _produce(s, pos, offset, written_ms, local_timeline):
            data, written_ms = chunk_info
            sent += len(data)
            publish()
            yield data
            await pace()
    finally:
        logger.info("rádio %s spojení #%d konec po %.1f s (%d kB)", s.id[:6], me, time.monotonic() - started, sent // 1024)


async def _produce(s: RadioSession, pos: int, offset: float, written_ms: float, timeline: list[Segment]):
    """Vyrábí MP3 bajty od pozice `pos` ve frontě; yielduje (data, čas streamu po nich)."""
    while pos < len(s.queue):
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
                yield chunk, written_ms
                waited += 1.0
                path, gain, pending = await asyncio.to_thread(_asset_path_and_gain, rid)
        if path is None:
            logger.info("rádio: %s nejde přehrát, přeskakuji", rid)
            pos += 1
            offset = 0.0
            continue

        looping = pos == 0 and s.ab_start_ms is not None and s.ab_end_ms is not None
        if looping:
            offset = s.ab_start_ms or 0.0
        seg = Segment(
            recording_id=rid,
            queue_pos=pos,
            start_ms=written_ms,
            offset_ms=offset,
            track_ms=await asyncio.to_thread(_probe_ms, path),
        )
        timeline.append(seg)
        length = (s.ab_end_ms - s.ab_start_ms) if looping and s.ab_end_ms and s.ab_start_ms is not None else None
        proc = await asyncio.create_subprocess_exec(
            *_ffmpeg_cmd(path, offset, gain, length), stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.DEVNULL
        )
        seg_bytes = 0
        try:
            assert proc.stdout is not None
            while True:
                data = await proc.stdout.read(CHUNK)
                if not data:
                    break
                seg_bytes += len(data)
                written_ms += len(data) / BYTES_PER_MS
                yield data, written_ms
        finally:
            if proc.returncode is None:
                try:
                    proc.kill()
                except ProcessLookupError:
                    pass
            await proc.wait()
        seg.duration_ms = seg_bytes / BYTES_PER_MS
        if looping and seg_bytes > 0:
            continue  # A-B: stejný úsek znovu (pos zůstává 0)
        pos += 1
        offset = 0.0
