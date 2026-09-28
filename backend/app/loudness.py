"""Analýza zvuku skladby -- jedno dekódování souboru ffmpegem pro dvě věci:

1. Hlasitostní normalizace (ReplayGain-styl, vzor z Finampu -- MPL-2.0, jen
   princip, ne kód): integrovaná hlasitost filtrem `ebur128` -> korekce v dB k
   cíli `TARGET_LUFS` do `MediaAsset.loudness_gain_db`. Klient ji aplikuje jako
   násobič hlasitosti (viz `AudioPlayerController` na klientovi).
2. Obrys hlasitosti ("waveform") pro vlnovku v přehrávači -- `WAVEFORM_BUCKETS`
   hodnot 0..255 (vnímaná hlasitost po úsecích skladby, nezávisle na délce) do
   `MediaAsset.waveform` (base64). Skutečná analýza zvuku za běhu na iOS Safari
   nejde, tohle je předpočítaný profil.

Finamp dostává korekci hotovou od Jellyfinu -- my žádný takový server nemáme,
takže obojí počítáme sami: hned po obstarání (worker) a průběžně na pozadí v
API procesu pro všechno ostatní (lokální sken, starší záznamy).
"""

from __future__ import annotations

import asyncio
import audioop  # noqa: DEP -- C implementace RMS, v Pythonu 3.12 pořád k dispozici
import base64
import logging
import math
import re
import shutil
import subprocess

from sqlalchemy import or_
from sqlmodel import Session, select

from app.db import engine
from app.models import MediaAsset, MediaAssetStatus

logger = logging.getLogger(__name__)

TARGET_LUFS = -14.0
MAX_GAIN_DB = 12.0
_ANALYSIS_TIMEOUT_S = 180
_INTEGRATED_RE = re.compile(r"I:\s+(-?\d+(?:\.\d+)?)\s+LUFS")

# Sentinel pro soubory, co ffmpeg nedokáže přečíst (dev placeholdery,
# poškozené soubory) -- bez něj by je backfill smyčka zkoušela znovu a znovu
# při každém průchodu. Mimo rozsah `±MAX_GAIN_DB`, takže ho nikdy nelze
# zaměnit za reálnou hodnotu; `gain_for_client` ho převede zpátky na `None`.
_UNMEASURABLE = -99.0

WAVEFORM_BUCKETS = 120
WAVEFORM_SAMPLE_RATE = 11025
# Prázdný řetězec = "zkoušeno, nejde změřit" (analogie `_UNMEASURABLE`) --
# `None` = ještě nezkoušeno.
_WAVEFORM_UNMEASURABLE = ""
# Rozsah vnímané hlasitosti, který se mapuje na 0..1 -- tišší úseky než
# `WAVEFORM_RANGE_DB` pod hlasitými vrcholy skladby jsou "ticho".
WAVEFORM_RANGE_DB = 36.0
WAVEFORM_MIN_RANGE_DB = 10.0
# Nejnižší zobrazená hodnota: tiché intro/breakdown je vidět, ne úplně rovné.
_WAVEFORM_FLOOR = 0.06


def _analysis_cmd(path: str) -> list[str]:
    """Jedno dekódování, dva výstupy: `ebur128` souhrn do stderr a mono PCM
    (s16le, 11 kHz) na stdout pro obrys hlasitosti."""
    cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-threads", "1",
        "-i", path, "-vn", "-sn", "-dn",
        "-filter_complex",
        "[0:a]asplit=2[l][w];"
        "[l]ebur128=framelog=quiet[lo];"
        f"[w]aresample={WAVEFORM_SAMPLE_RATE},aformat=sample_fmts=s16:channel_layouts=mono[wo]",
        "-map", "[lo]", "-f", "null", "/dev/null",
        "-map", "[wo]", "-f", "s16le", "pipe:1",
    ]
    # Nejnižší priorita -- analýza nesmí zpomalit přehrávání/stahování, co
    # běží ve stejném kontejneru.
    if shutil.which("nice"):
        cmd = ["nice", "-n", "19", *cmd]
    return cmd


def measure(path: str) -> tuple[float | None, bytes | None]:
    """Vrátí `(integrated_lufs, pcm_s16le_mono)`; `None` tam, kde se to
    změřit nepovedlo."""
    try:
        proc = subprocess.run(_analysis_cmd(path), capture_output=True, timeout=_ANALYSIS_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as exc:
        logger.warning("analýza: ffmpeg selhal pro %s: %s", path, exc)
        return None, None
    stderr = proc.stderr.decode("utf-8", "replace")
    matches = _INTEGRATED_RE.findall(stderr)
    # Poslední shoda = souhrn na konci (`framelog=quiet` průběžné řádky
    # potlačí, ale pro jistotu nebereme první).
    lufs = float(matches[-1]) if proc.returncode == 0 and matches else None
    pcm = proc.stdout if proc.returncode == 0 and proc.stdout else None
    return lufs, pcm


def measure_integrated_lufs(path: str) -> float | None:
    return measure(path)[0]


def gain_for_lufs(lufs: float) -> float:
    return round(max(-MAX_GAIN_DB, min(MAX_GAIN_DB, TARGET_LUFS - lufs)), 2)


def gain_for_client(stored: float | None) -> float | None:
    if stored is None or stored <= _UNMEASURABLE:
        return None
    return stored


def envelope_from_pcm(pcm: bytes, buckets: int = WAVEFORM_BUCKETS) -> list[int] | None:
    """Obrys vnímané hlasitosti: skladba rozdělená na `buckets` stejných
    úseků, v každém průměr hlasitosti (dB) přes ~100 ms okna -- průměr v dB
    odpovídá vnímání líp než špičky. Normalizace ke hlasitým místům skladby
    (95. percentil), jemná křivka, lehké vyhlazení, výsledek 0..255."""
    samples = len(pcm) // 2
    if samples < buckets * 64:
        return None
    per_bucket = samples // buckets
    window = max(64, WAVEFORM_SAMPLE_RATE // 10)

    levels: list[float] = []
    for b in range(buckets):
        start = b * per_bucket * 2
        chunk = pcm[start : start + per_bucket * 2]
        dbs = []
        for offset in range(0, len(chunk) - 1, window * 2):
            part = chunk[offset : offset + window * 2]
            if len(part) < 4:
                continue
            rms = audioop.rms(part, 2)
            dbs.append(20 * math.log10(max(rms, 1) / 32768))
        levels.append(sum(dbs) / len(dbs) if dbs else -90.0)

    ordered = sorted(levels)
    top = ordered[int(len(ordered) * 0.95) - 1]
    low = ordered[int(len(ordered) * 0.05)]
    # Rozsah podle dynamiky skladby: silně komprimovaný rock se hýbe jen o
    # pár dB -- s pevným rozsahem by vyšel jako plný blok bez tvaru.
    # Omezeno na [WAVEFORM_MIN_RANGE_DB, WAVEFORM_RANGE_DB], ať se drobné
    # výkyvy nepřehánějí a tiché pasáže dynamických skladeb pořád klesnou.
    span = min(WAVEFORM_RANGE_DB, max(WAVEFORM_MIN_RANGE_DB, top - low + 4))
    floor_db = top - span
    values = []
    for db in levels:
        v = min(1.0, max(0.0, (db - floor_db) / span))
        values.append(_WAVEFORM_FLOOR + (1 - _WAVEFORM_FLOOR) * v**1.25)

    smoothed = [
        0.25 * values[max(i - 1, 0)] + 0.5 * values[i] + 0.25 * values[min(i + 1, len(values) - 1)]
        for i in range(len(values))
    ]
    return [round(v * 255) for v in smoothed]


def encode_waveform(buckets: list[int]) -> str:
    return base64.b64encode(bytes(buckets)).decode("ascii")


def decode_waveform(stored: str | None) -> list[int] | None:
    if not stored:
        return None
    try:
        return list(base64.b64decode(stored))
    except (ValueError, TypeError):
        return None


def analyze_and_store(recording_id: str) -> float | None:
    """Sync -- volat přes `asyncio.to_thread`. Změří korekci hlasitosti i
    obrys hlasitosti v jednom průchodu a uloží je. Vrátí korekci (nebo
    `None`, když se soubor změřit nepovedlo)."""
    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        if asset is None or asset.status != MediaAssetStatus.AVAILABLE or not asset.storage_path:
            return None
        path = asset.storage_path

    lufs, pcm = measure(path)
    gain = gain_for_lufs(lufs) if lufs is not None else _UNMEASURABLE
    buckets = envelope_from_pcm(pcm) if pcm else None
    duration_ms = round(len(pcm) / 2 / WAVEFORM_SAMPLE_RATE * 1000) if pcm else None

    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        # Mezitím mohl soubor zmizet/změnit se (re-provisioning) -- zapíšeme
        # jen když pořád ukazuje na stejný soubor, co jsme měřili.
        if asset is None or asset.storage_path != path:
            return None
        asset.loudness_gain_db = gain
        asset.waveform = encode_waveform(buckets) if buckets else _WAVEFORM_UNMEASURABLE
        asset.waveform_duration_ms = duration_ms if buckets else None
        session.add(asset)
        session.commit()
    return gain_for_client(gain)


def _pending_ids(limit: int) -> list[str]:
    with Session(engine) as session:
        return list(
            session.exec(
                select(MediaAsset.recording_id)
                .where(
                    MediaAsset.status == MediaAssetStatus.AVAILABLE,
                    or_(
                        MediaAsset.loudness_gain_db.is_(None),  # type: ignore[union-attr]
                        MediaAsset.waveform.is_(None),  # type: ignore[union-attr]
                    ),
                )
                .limit(limit)
            ).all()
        )


backfill_progress: dict[str, int | bool] = {"running": False, "processed": 0, "remaining": 0}


async def backfill_loop(idle_interval_s: float = 120.0, pause_s: float = 0.5) -> None:
    """Běží na pozadí v API procesu po celou dobu jeho života: postupně (vždy
    jen jedna analýza naráz, s pauzou mezi nimi) doměří všechny AVAILABLE
    skladby bez korekce hlasitosti nebo bez obrysu hlasitosti -- starší
    záznamy i nově naskenované lokální soubory (`library/scanner.py` je
    zakládá rovnou jako AVAILABLE a tahle smyčka je do pár minut vyzvedne,
    bez zdržování samotného skenu). Když není co měřit, jen občas
    zkontroluje, jestli něco nepřibylo."""
    while True:
        try:
            batch = await asyncio.to_thread(_pending_ids, 50)
            if not batch:
                backfill_progress.update(running=False, remaining=0)
                await asyncio.sleep(idle_interval_s)
                continue
            backfill_progress["running"] = True
            for recording_id in batch:
                await asyncio.to_thread(analyze_and_store, recording_id)
                backfill_progress["processed"] = int(backfill_progress["processed"]) + 1
                await asyncio.sleep(pause_s)
            backfill_progress["remaining"] = len(await asyncio.to_thread(_pending_ids, 100000))
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - smyčka nesmí nikdy umřít kvůli jedné skladbě
            logger.exception("analýza backfill: chyba v dávce, zkusím za chvíli znovu")
            await asyncio.sleep(idle_interval_s)
