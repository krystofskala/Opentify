"""Hlasitostní normalizace (ReplayGain-styl, vzor z Finampu -- MPL-2.0, jen
princip, ne kód): jednorázově změří integrovanou hlasitost skladby ffmpeg
filtrem `ebur128` a uloží korekci v dB k cíli `TARGET_LUFS` do
`MediaAsset.loudness_gain_db`. Klient ji pak aplikuje jako násobič hlasitosti
(viz `AudioPlayerController` na klientovi).

Finamp tu hodnotu dostává hotovou od Jellyfinu (server ji počítá při skenu
knihovny) -- my žádný takový server nemáme, takže ji počítáme sami: hned po
obstarání (worker) a průběžně na pozadí v API procesu pro všechno ostatní
(lokální sken, starší záznamy před zavedením téhle funkce).
"""

from __future__ import annotations

import asyncio
import logging
import re
import shutil
import subprocess

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


def measure_integrated_lufs(path: str) -> float | None:
    cmd = [
        "ffmpeg", "-hide_banner", "-nostats", "-threads", "1",
        "-i", path, "-vn", "-sn", "-dn",
        "-filter_complex", "ebur128=framelog=quiet",
        "-f", "null", "-",
    ]
    # Nejnižší priorita -- analýza nesmí zpomalit přehrávání/stahování, co
    # běží ve stejném kontejneru.
    if shutil.which("nice"):
        cmd = ["nice", "-n", "19", *cmd]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=_ANALYSIS_TIMEOUT_S)
    except (OSError, subprocess.TimeoutExpired) as exc:
        logger.warning("loudness: ffmpeg selhal pro %s: %s", path, exc)
        return None
    matches = _INTEGRATED_RE.findall(proc.stderr)
    if proc.returncode != 0 or not matches:
        return None
    # Poslední shoda = souhrn na konci (`framelog=quiet` průběžné řádky
    # potlačí, ale pro jistotu nebereme první).
    return float(matches[-1])


def gain_for_lufs(lufs: float) -> float:
    return round(max(-MAX_GAIN_DB, min(MAX_GAIN_DB, TARGET_LUFS - lufs)), 2)


def gain_for_client(stored: float | None) -> float | None:
    if stored is None or stored <= _UNMEASURABLE:
        return None
    return stored


def analyze_and_store(recording_id: str) -> float | None:
    """Sync -- volat přes `asyncio.to_thread`. Vrátí uloženou korekci (nebo
    `None`, když se soubor změřit nepovedlo)."""
    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        if asset is None or asset.status != MediaAssetStatus.AVAILABLE or not asset.storage_path:
            return None
        path = asset.storage_path

    lufs = measure_integrated_lufs(path)
    gain = gain_for_lufs(lufs) if lufs is not None else _UNMEASURABLE

    with Session(engine) as session:
        asset = session.get(MediaAsset, recording_id)
        # Mezitím mohl soubor zmizet/změnit se (re-provisioning) -- zapíšeme
        # jen když pořád ukazuje na stejný soubor, co jsme měřili.
        if asset is None or asset.storage_path != path:
            return None
        asset.loudness_gain_db = gain
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
                    MediaAsset.loudness_gain_db.is_(None),  # type: ignore[union-attr]
                )
                .limit(limit)
            ).all()
        )


backfill_progress: dict[str, int | bool] = {"running": False, "processed": 0, "remaining": 0}


async def backfill_loop(idle_interval_s: float = 120.0, pause_between_s: float = 0.5) -> None:
    """Běží na pozadí v API procesu po celou dobu jeho života: postupně (vždy
    jen jedna analýza naráz, s pauzou mezi nimi) doměří všechny AVAILABLE
    skladby bez `loudness_gain_db` -- starší záznamy i nově naskenované
    lokální soubory (`library/scanner.py` je zakládá rovnou jako AVAILABLE a
    tahle smyčka je do pár minut vyzvedne, bez zdržování samotného skenu).
    Když není co měřit, jen občas zkontroluje, jestli něco nepřibylo."""
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
                await asyncio.sleep(pause_between_s)
            backfill_progress["remaining"] = len(await asyncio.to_thread(_pending_ids, 100000))
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 - smyčka nesmí nikdy umřít kvůli jedné skladbě
            logger.exception("loudness backfill: chyba v dávce, zkusím za chvíli znovu")
            await asyncio.sleep(idle_interval_s)
