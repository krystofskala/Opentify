"""Rozbor zvuku z 30s ukázky Deezeru -- pro skladby, které ještě nejsou
stažené (nové v Pusť teď, objevy). Bez něj by řazení podle plynulosti a
nálady zvuku nové skladby nevidělo (dostaly by průměr).

- Ukázka se jen stáhne do paměti, dekóduje a zahodí (nic se neukládá).
- Výsledek jde do `TrackFeatures` s `version = 0`: až se stáhne celý
  soubor, rozbor z něj ho přepíše (`loudness._pending_ids` bere starší verze).
- Ukázka je kus ze středu skladby, takže začátek/konec = energie ukázky a
  hlasitost okrajů se nevyplňuje (nevíme).
"""

from __future__ import annotations

import asyncio
import logging
import subprocess

import httpx
from sqlmodel import Session, select

from app.db import engine

logger = logging.getLogger(__name__)

PREVIEW_VERSION = 0
_TIMEOUT_S = 15
_sem = asyncio.Semaphore(3)
_background: set[asyncio.Task] = set()  # co nestihne limit, doběhne na pozadí


def _decode(data: bytes) -> bytes | None:
    from app.audio_features import SR

    try:
        proc = subprocess.run(
            ["ffmpeg", "-hide_banner", "-nostats", "-loglevel", "error", "-i", "pipe:0",
             "-vn", "-ac", "1", "-ar", str(SR), "-f", "s16le", "pipe:1"],
            input=data, capture_output=True, timeout=_TIMEOUT_S,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    return proc.stdout if proc.returncode == 0 and proc.stdout else None


def _store(recording_id: str, features: dict) -> None:
    from app.models import TrackFeatures
    from app.utils import utcnow

    with Session(engine) as session:
        row = session.get(TrackFeatures, recording_id)
        if row is not None and row.version > PREVIEW_VERSION:
            return  # mezitím rozbor z celého souboru -- ten má přednost
        row = row or TrackFeatures(recording_id=recording_id)
        row.energy = features.get("energy")
        row.intro_energy = row.outro_energy = features.get("energy")
        row.intro_level_db = row.outro_level_db = None
        row.bpm = features.get("bpm")
        row.bpm_confidence = features.get("bpm_confidence")
        row.flatness = features.get("flatness")
        row.high_ratio = features.get("high_ratio")
        row.centroid_hz = features.get("centroid_hz")
        row.version = PREVIEW_VERSION
        row.updated_at = utcnow()
        session.add(row)
        session.commit()


async def analyze(recording_id: str, deezer_id: str) -> bool:
    from app.catalog.deezer import get_deezer_client

    try:
        track = await get_deezer_client().track(str(deezer_id))
    except Exception as exc:  # noqa: BLE001
        logger.info("ukázka %s: %s", recording_id[:8], exc)
        return False
    url = (track or {}).get("preview")
    return bool(url) and await analyze_url(recording_id, url)


async def analyze_url(recording_id: str, url: str) -> bool:
    from app import audio_features

    async with _sem:
        try:
            async with httpx.AsyncClient(timeout=_TIMEOUT_S, follow_redirects=True) as client:
                resp = await client.get(url)
                resp.raise_for_status()
            pcm = await asyncio.to_thread(_decode, resp.content)
            features = await asyncio.to_thread(audio_features.compute, pcm) if pcm else None
        except Exception as exc:  # noqa: BLE001 -- doplněk, nesmí nic shodit
            logger.info("ukázka %s: %s", recording_id[:8], exc)
            return False
    if not features:
        return False
    await asyncio.to_thread(_store, recording_id, features)
    return True


def _missing(recording_ids: list[str]) -> list[tuple[str, str]]:
    from app.models import Recording, TrackFeatures

    with Session(engine) as session:
        have = set(
            session.exec(select(TrackFeatures.recording_id).where(TrackFeatures.recording_id.in_(recording_ids))).all()  # type: ignore[attr-defined]
        )
        rows = session.exec(
            select(Recording.id, Recording.deezer_id).where(Recording.id.in_([r for r in recording_ids if r not in have]))  # type: ignore[attr-defined]
        ).all()
    return [(rid, dz) for rid, dz in rows if dz and not str(dz).startswith("own:")]


async def ensure(recording_ids: list[str], timeout_s: float = 4.0) -> int:
    """Rozebrat ukázky skladeb bez rozboru; čeká nejvýš `timeout_s` (co
    nestihne, doběhne na pozadí a pomůže příští várce). Vrací počet hotových."""
    todo = await asyncio.to_thread(_missing, list(dict.fromkeys(recording_ids)))
    if not todo:
        return 0
    tasks = [asyncio.ensure_future(analyze(rid, dz)) for rid, dz in todo]
    for t in tasks:
        _background.add(t)
        t.add_done_callback(_background.discard)
    done, _pending = await asyncio.wait(tasks, timeout=timeout_s)
    return sum(1 for t in done if not t.cancelled() and t.exception() is None and t.result())


# Doplňování na pozadí (13. 10.): rozbor měla jen ~5 % poslouchaných skladeb
# (jen stažené a nové z Pusť teď), plynulé řazení bylo u známých naslepo.
# Napřed skladby s nejvíc poslechy napříč profily; bez ukázky se 30 dní
# nezkouší znovu. Pomalu a s nižší prioritou než to, co otevřel uživatel.
BACKFILL_BATCH = 200
BACKFILL_PAUSE_S = 2.0
BACKFILL_MIN_LISTENS = 2
_MISS_TTL_S = 30 * 86400


def _miss_key(recording_id: str) -> str:
    return f"preview-features:miss:{recording_id}"


def _backfill_candidates(limit: int) -> list[tuple[str, str | None, str, str, int | None]]:
    """(skladba, deezer id nebo None, interpret, název, délka ms)."""
    from sqlalchemy import text

    with Session(engine) as session:
        rows = session.exec(  # type: ignore[call-overload]
            text(
                "SELECT r.id, r.deezer_id, a.name, r.title, r.duration_ms FROM listen l "
                "JOIN recording r ON r.id = l.recording_id "
                "JOIN artist a ON a.id = r.artist_id "
                "LEFT JOIN trackfeatures f ON f.recording_id = l.recording_id "
                "WHERE f.recording_id IS NULL AND (r.deezer_id IS NULL OR r.deezer_id NOT LIKE 'own:%') "
                "GROUP BY r.id HAVING COUNT(*) >= :min ORDER BY COUNT(*) DESC LIMIT :lim"
            ).bindparams(min=BACKFILL_MIN_LISTENS, lim=limit * 3)
        ).all()
    if not rows:
        return []
    try:
        from app.redis_bus import get_redis

        missed = get_redis().mget([_miss_key(r[0]) for r in rows])
    except Exception:  # noqa: BLE001
        missed = [None] * len(rows)
    return [(rid, str(dz) if dz else None, name, title, dur) for (rid, dz, name, title, dur), m in zip(rows, missed) if not m][:limit]


def _plain(title: str) -> str:
    from app.catalog.service import normalize_title  # i bez závorkových dovětků

    return normalize_title(title or "")


async def _search_preview(artist: str, title: str, duration_ms: int | None) -> str | None:
    """Ukázka stejné skladby na Deezeru podle jména (skladba bez deezer id):
    stejný interpret, stejný název bez závorek, délka do 8 s. Jen pro rozbor
    zvuku -- katalog se tím nemění."""
    from app.catalog.artwork import same_artist_name
    from app.catalog.deezer import get_deezer_client

    try:
        res = await get_deezer_client().search(f'artist:"{artist}" track:"{title}"', 5)
    except Exception:  # noqa: BLE001
        return None
    want = _plain(title)
    for hit in (res or {}).get("data") or []:
        if not hit.get("preview") or not same_artist_name((hit.get("artist") or {}).get("name", ""), artist):
            continue
        if _plain(hit.get("title") or "") != want:
            continue
        if duration_ms and hit.get("duration") and abs(hit["duration"] * 1000 - duration_ms) > 8000:
            continue
        return hit["preview"]
    return None


def _mark_miss(recording_id: str) -> None:
    try:
        from app.redis_bus import get_redis

        get_redis().set(_miss_key(recording_id), 1, ex=_MISS_TTL_S)
    except Exception:  # noqa: BLE001
        pass


async def backfill_loop() -> None:
    from app.catalog.rate_limit import mark_background

    mark_background()
    await asyncio.sleep(300)  # po startu nechat doběhnout Domů
    while True:
        try:
            todo = await asyncio.to_thread(_backfill_candidates, BACKFILL_BATCH)
            if not todo:
                await asyncio.sleep(6 * 3600)
                continue
            done = 0
            for rid, dz, artist, title, dur in todo:
                if dz:
                    ok = await analyze(rid, dz)
                else:
                    url = await _search_preview(artist, title, dur)
                    ok = bool(url) and await analyze_url(rid, url)
                if ok:
                    done += 1
                else:
                    await asyncio.to_thread(_mark_miss, rid)
                await asyncio.sleep(BACKFILL_PAUSE_S)
            logger.info("rozbor ukázek na pozadí: %d z %d", done, len(todo))
        except asyncio.CancelledError:
            raise
        except Exception:  # noqa: BLE001 -- smyčka nesmí umřít
            logger.exception("rozbor ukázek na pozadí selhal")
            await asyncio.sleep(600)
