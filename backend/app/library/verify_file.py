"""Ověření staženého souboru DŘÍV, než se ukáže v knihovně.

Dřív se soubor označil jako dostupný hned a kontrola (délka + Shazam) jen
zapsala nález do přehledu -- špatná skladba tak hrála dál. Audit 2026-10-03
našel ~10 % špatných souborů ze Soulseeku i YouTube (živáky, jiné písně,
useknuté FLACy, 617 B "skladba"). Teď:

1. integrita -- ffprobe otevře soubor, je to zvuk, délka > 30 s, kontejner
   odpovídá příponě (Opus v ".flac" se přejmenuje), u souborů ze Soulseeku
   i plné dekódování bez chyb;
2. otisk -- 30s ukázka z Deezeru (přesná verze skladby) se hledá uvnitř
   souboru (chromaprint z ffmpeg, posuvné porovnání). Spolehlivě rozliší
   jinou nahrávku (živák, demo, jiná píseň) a potvrdí správnou i s intrem
   z videoklipu (správné soubory BER <= 0.06, špatné >= 0.35);
3. bez ukázky: délka proti katalogu a tagy v souboru (Soulseek -- soubor
   nese název, pod kterým ho člověk sdílí);
4. AcoustID (je-li klíč): otisk -> MusicBrainz nahrávky; jiný interpret /
   jiná píseň = špatně.

`verify()` vrací `Verdict`; `ok=False` = soubor zahodit, zdroj zakázat
a zkusit dalšího kandidáta (worker.handle_job).
"""

from __future__ import annotations

import asyncio
import json
import logging
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import numpy as np

from app.download_match import artist_in, duration_ok, fold, match_label

logger = logging.getLogger("vault.verify")

MATCH_BER = 0.22  # pod tím = ukázka je v souboru (stejná nahrávka)
NO_MATCH_BER = 0.33  # nad tím = ukázka v souboru není (jiná nahrávka)
SURE_NO_MATCH_BER = 0.38  # 0.33-0.38 zamítnout jen s nesedící délkou

_CONTAINER_EXT = {"flac": ".flac", "mp3": ".mp3", "ogg": ".ogg", "mov,mp4,m4a,3gp,3g2,mj2": ".m4a", "wav": ".wav"}


@dataclass
class Verdict:
    ok: bool
    reason: str
    confidence: str = "low"  # high (otisk/AcoustID potvrdil) / medium (délka+tagy) / low
    path: Path | None = None  # skutečná cesta (po opravě přípony)
    details: dict = field(default_factory=dict)


@dataclass
class Target:
    recording_id: str
    title: str
    artist: str | None
    album: str | None
    expected_ms: int | None
    deezer_id: str | None = None
    isrc: str | None = None
    mbid: str | None = None
    provider: str = ""
    # Delší soubor je v pořádku, když je to oficiální videoklip (intro).
    allow_padding: bool = False
    # Otisky dřív zamítnutých souborů (viz `signature`) -- stejný zvuk z
    # jiného zdroje se znovu nepřijme.
    rejected_fps: tuple[str, ...] = ()


async def _run(args: list[str], timeout: float) -> tuple[int, bytes, bytes]:
    proc = await asyncio.create_subprocess_exec(*args, stdout=asyncio.subprocess.PIPE, stderr=asyncio.subprocess.PIPE)
    try:
        out, err = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        await proc.wait()
        return -1, b"", b"timeout"
    return proc.returncode or 0, out, err


async def probe(path: Path) -> dict | None:
    code, out, _err = await _run(
        ["ffprobe", "-v", "error", "-show_entries", "format=format_name,duration,bit_rate:stream=codec_type,codec_name,bit_rate",
         "-of", "json", str(path)],
        30,
    )
    if code != 0:
        return None
    try:
        data = json.loads(out or b"{}")
    except ValueError:
        return None
    audio = [s for s in data.get("streams") or [] if s.get("codec_type") == "audio"]
    fmt = data.get("format") or {}
    if not audio:
        return None
    try:
        duration = float(fmt.get("duration") or 0)
    except ValueError:
        duration = 0.0
    bit_rate = fmt.get("bit_rate") or audio[0].get("bit_rate")
    return {
        "container": fmt.get("format_name") or "",
        "codec": audio[0].get("codec_name") or "",
        "duration": duration,
        "kbps": int(int(bit_rate) / 1000) if bit_rate and str(bit_rate).isdigit() else None,
    }


async def decodes_cleanly(path: Path) -> bool:
    code, _out, err = await _run(["ffmpeg", "-v", "error", "-xerror", "-i", str(path), "-f", "null", "-"], 120)
    return code == 0 and not err.strip()


async def fingerprint(source: str, seconds: int | None = None) -> np.ndarray | None:
    args = ["ffmpeg", "-v", "error", "-i", source, "-ac", "1"]
    if seconds:
        args += ["-t", str(seconds)]
    args += ["-f", "chromaprint", "-fp_format", "raw", "-"]
    code, out, _err = await _run(args, 90)
    if code != 0 or len(out) < 64:
        return None
    return np.frombuffer(out[: len(out) // 4 * 4], dtype="<u4")


def fingerprint_worth_keeping(reason: str) -> bool:
    """Otisk zamítnutého souboru má smysl jen u JINÉ nahrávky. Soubor, který
    "obsahuje víc než skladbu" (celé album / dlouhé video), tu správnou píseň
    obsahuje -- jeho otisk by odmítl i každé správné stažení (živě: Norman
    fucking Rockwell, Something in the Way)."""
    return reason.startswith(("jiná nahrávka", "AcoustID", "soubor je podle tagů"))


async def signature(path: Path) -> str | None:
    """Krátký otisk souboru (~50 s od 20. sekundy) pro `Target.rejected_fps`."""
    import base64

    fp = await fingerprint(str(path), seconds=90)
    if fp is None or len(fp) < 80:
        return None
    part = fp[160:560] if len(fp) >= 400 else fp
    return base64.b64encode(part.astype("<u4").tobytes()).decode()


def _from_signature(sig: str) -> np.ndarray | None:
    import base64

    try:
        return np.frombuffer(base64.b64decode(sig), dtype="<u4")
    except ValueError:
        return None


def best_ber(haystack: np.ndarray, needle: np.ndarray) -> float:
    """Nejlepší shoda `needle` (ukázka) kdekoli v `haystack` (soubor):
    podíl rozdílných bitů otisku, 0 = totožné, ~0.5 = nesouvisející."""
    if len(needle) > len(haystack):
        haystack, needle = needle, haystack
    # Okraje ukázky (fade in/out na Deezeru) vynechat.
    trim = max(0, (len(needle) - 120) // 6)
    core = needle[trim : len(needle) - trim] if len(needle) - 2 * trim >= 60 else needle
    windows = np.lib.stride_tricks.sliding_window_view(haystack, len(core))
    diff = np.bitwise_count(np.bitwise_xor(windows, core)).mean(axis=1) / 32.0
    return float(diff.min())


async def _preview_url(target: Target) -> tuple[str | None, int | None]:
    """URL 30s ukázky PŘESNĚ té verze + délka té verze na Deezeru."""
    from app.catalog.deezer import get_deezer_client

    dz = get_deezer_client()
    track = None
    try:
        if target.deezer_id:
            track = await dz.track(str(target.deezer_id))
        if track is None and target.isrc:
            found = await dz.find_track_by_isrc(target.isrc)
            # ISRC bývá sdílené mezi verzemi -- jen se stejným názvem.
            if found and match_label(target.title, found.get("title") or "", artist=target.artist) is None:
                track = found
    except Exception as exc:  # noqa: BLE001 - doplněk
        logger.info("verify %s: Deezer nedostupný (%s)", target.recording_id, exc)
        return None, None
    if not track or not track.get("preview"):
        return None, None
    return track["preview"], (int(track["duration"]) * 1000 if track.get("duration") else None)


async def _reference(target: Target) -> tuple[np.ndarray | None, int | None]:
    url, dz_ms = await _preview_url(target)
    if not url:
        return None, None
    import httpx

    try:
        async with httpx.AsyncClient(timeout=15, follow_redirects=True) as client:
            resp = await client.get(url)
            resp.raise_for_status()
    except Exception:  # noqa: BLE001
        return None, None
    with tempfile.NamedTemporaryFile(suffix=".mp3", delete=False) as tmp:
        tmp.write(resp.content)
    try:
        return await fingerprint(tmp.name), dz_ms
    finally:
        os.unlink(tmp.name)


async def resolve_duration(target: Target) -> tuple[int | None, str | None]:
    """Délka skladby, kterou katalog nemá (31 % nahrávek) -- z Deezeru, ale
    jen při jisté shodě: přesný název (stejná verze), stejný interpret a, je-li
    známé, stejné album (singl a album mívají jiný střih). Vrací (ms,
    deezer_id). Bez délky se dřív stahovalo bez kontroly délky vůbec."""
    from app.catalog.deezer import get_deezer_client
    from app.download_match import core_tokens

    dz = get_deezer_client()

    def fits(track: dict | None) -> bool:
        if not track or not track.get("duration"):
            return False
        if match_label(target.title, track.get("title") or "", artist=target.artist) is not None:
            return False
        if not artist_in(target.artist, (track.get("artist") or {}).get("name") or ""):
            return False
        album = (track.get("album") or {}).get("title") or ""
        return not target.album or core_tokens(album) == core_tokens(target.album)

    try:
        if target.deezer_id:
            track = await dz.track(str(target.deezer_id))
            if track and track.get("duration") and match_label(target.title, track.get("title") or "", artist=target.artist) is None:
                return int(track["duration"]) * 1000, str(target.deezer_id)
        if target.isrc:
            track = await dz.find_track_by_isrc(target.isrc)
            if fits(track):
                return int(track["duration"]) * 1000, str(track["id"])
        if target.artist:
            found = await dz.search_typed("track", f'artist:"{target.artist}" track:"{target.title}"', 5) or []
            hits = [t for t in found if fits(t)]
            durations = {int(t["duration"]) for t in hits}
            # Víc verzí stejného jména s různou délkou = nevíme která.
            if hits and max(durations) - min(durations) <= 4:
                return int(hits[0]["duration"]) * 1000, str(hits[0]["id"])
    except Exception as exc:  # noqa: BLE001 - bez délky se jen méně kontroluje
        logger.info("délka %s: Deezer nedostupný (%s)", target.recording_id, exc)
    return None, None


def _tags(path: Path) -> tuple[str | None, str | None]:
    try:
        from mutagen import File as MutagenFile

        audio = MutagenFile(str(path), easy=True)
    except Exception:  # noqa: BLE001
        return None, None
    if audio is None or not audio.tags:
        return None, None

    def first(key: str) -> str | None:
        value = audio.tags.get(key)
        return str(value[0]) if value else None

    return first("title"), first("artist")


async def _acoustid(path: Path, duration: float, target: Target) -> str | None:
    """'match' / 'mismatch' / None (nevíme). Jen přes VPN proxy, bez osobních údajů."""
    key = os.environ.get("ACOUSTID_API_KEY")
    proxy = os.environ.get("SHAZAM_PROXY", "http://gluetun:8888").strip()
    if not key or not proxy:
        return None
    code, out, _err = await _run(
        ["ffmpeg", "-v", "error", "-i", str(path), "-ac", "1", "-t", "120", "-f", "chromaprint", "-fp_format", "base64", "-"], 60
    )
    fp = out.decode().strip() if code == 0 else ""
    if not fp:
        return None
    import httpx

    from app.catalog.rate_limit import AsyncRateLimiter

    await AsyncRateLimiter(min_interval_seconds=0.4, key="acoustid").wait()
    try:
        async with httpx.AsyncClient(proxy=proxy, timeout=15) as client:
            resp = await client.post(
                "https://api.acoustid.org/v2/lookup",
                data={"client": key, "meta": "recordings", "duration": str(int(duration)), "fingerprint": fp},
            )
            data = resp.json()
    except Exception:  # noqa: BLE001
        return None
    results = [r for r in data.get("results") or [] if (r.get("score") or 0) >= 0.8 and r.get("recordings")]
    if not results:
        return None
    recordings = [rec for r in results for rec in r["recordings"]]
    if target.mbid and any(rec.get("id") == target.mbid for rec in recordings):
        return "match"
    named = [rec for rec in recordings if rec.get("title")]
    if not named:
        return None
    for rec in named:
        artists = " ".join(a.get("name", "") for a in rec.get("artists") or [])
        if artist_in(target.artist, artists) and match_label(target.title, rec["title"], artist=target.artist) is None:
            return "match"
    # Silná shoda otisku s úplně jiným interpretem i názvem = jiná píseň.
    if all(not artist_in(target.artist, " ".join(a.get("name", "") for a in rec.get("artists") or [])) for rec in named):
        return "mismatch"
    if all(fold(rec["title"]) != fold(target.title) and match_label(target.title, rec["title"]) for rec in named):
        return "mismatch"
    return None


async def _fix_extension(path: Path, info: dict) -> Path:
    want = _CONTAINER_EXT.get(info["container"])
    if info["container"] == "ogg" and info["codec"] == "opus":
        want = ".opus"
    if want and path.suffix.lower() != want and not (want == ".m4a" and path.suffix.lower() in (".mp4", ".m4a")):
        fixed = path.with_suffix(want)
        await asyncio.to_thread(path.rename, fixed)
        logger.warning("verify: %s je ve skutečnosti %s -> %s", path.name, info["container"], fixed.name)
        return fixed
    return path


async def verify(path: Path, target: Target, *, full_decode: bool = False, fix_ext: bool = True) -> Verdict:
    info = await probe(path)
    if info is None:
        return Verdict(False, "soubor nejde otevřít / není to zvuk", path=path)
    if info["duration"] < 30:
        return Verdict(False, f"jen {info['duration']:.0f} s", path=path, details=info)
    if fix_ext:
        path = await _fix_extension(path, info)
    if full_decode and not await decodes_cleanly(path):
        return Verdict(False, "soubor je poškozený (chyby při dekódování)", path=path, details=info)

    actual = info["duration"]
    expected = target.expected_ms / 1000 if target.expected_ms else None
    details: dict = {**info}

    ref, ref_ms = await _reference(target)
    file_fp = await fingerprint(str(path), seconds=900) if (ref is not None or target.rejected_fps) else None
    # Otisk dřív zamítnutého souboru platí jen tehdy, když ukázka z Deezeru
    # shodu nepotvrdí -- zkrácený edit ("A Forest" z Greatest Hits) sdílí zvuk
    # se správnou albovou verzí a blokoval by ji.
    ref_confirms = False
    if ref is not None and file_fp is not None and len(file_fp) >= 40:
        ref_confirms = best_ber(file_fp, ref) <= MATCH_BER
    for sig in () if ref_confirms else target.rejected_fps:
        old_fp = _from_signature(sig)
        if file_fp is not None and old_fp is not None and len(old_fp) >= 40 and best_ber(file_fp, old_fp) <= 0.15:
            return Verdict(False, "stejný zvuk jako dřív zamítnutý soubor", path=path, details=details)
    if ref is not None:
        if file_fp is not None and len(file_fp) >= 40:
            ber = best_ber(file_fp, ref)
            details["ber"] = round(ber, 3)
            # Ukázce věřit k zamítnutí jen když je to opravdu tahle verze
            # (délka na Deezeru = délka v katalogu).
            trusted = bool(ref_ms and expected and abs(ref_ms / 1000 - expected) <= max(4.0, expected * 0.03))
            if ber <= MATCH_BER:
                if expected and actual > expected * 1.6 + 30:
                    # Ukázka je uvnitř, ale soubor je mnohem delší (celé album, mix).
                    return Verdict(False, f"obsahuje víc než skladbu ({actual:.0f} s místo {expected:.0f} s)", path=path, details=details)
                return Verdict(True, "otisk sedí", "high", path=path, details=details)
            # Pásmo těsně nad hranicí (0.33-0.38) může být jen jiný master --
            # zamítnout jen když nesedí ani délka.
            borderline = ber < SURE_NO_MATCH_BER and bool(expected) and duration_ok(expected, actual, strict=True)
            if ber >= NO_MATCH_BER and trusted and not borderline:
                return Verdict(False, f"jiná nahrávka (otisk {ber:.2f})", path=path, details=details)

    # Bez spolehlivé ukázky: délka, tagy, AcoustID.
    if expected:
        tol_ok = duration_ok(expected, actual, strict=False)
        if not tol_ok and not (target.allow_padding and expected <= actual <= expected + max(45.0, expected * 0.25)):
            return Verdict(False, f"délka {actual:.0f} s místo {expected:.0f} s", path=path, details=details)
    tag_title, tag_artist = await asyncio.to_thread(_tags, path) if target.provider == "slskd" else (None, None)
    if tag_title:
        details["tag"] = f"{tag_artist} – {tag_title}"
        why = match_label(target.title, tag_title, artist=target.artist, album=target.album)
        if why and why.startswith(("jiná", "chybí název")):
            return Verdict(False, f"soubor je podle tagů '{tag_title}' ({why})", path=path, details=details)
    acoustid = await _acoustid(path, actual, target)
    if acoustid:
        details["acoustid"] = acoustid
        if acoustid == "mismatch":
            return Verdict(False, "AcoustID: jiná skladba", path=path, details=details)
        return Verdict(True, "AcoustID sedí", "high", path=path, details=details)
    return Verdict(True, "délka sedí" if expected else "bez reference", "medium" if expected else "low", path=path, details=details)
