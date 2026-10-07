"""Audioknihy ze Soulseeku -- záloha, když česká verze (SkTorrent) není
(typicky anglické originály). Stejný slskd jako u hudby: hledání se
seskupí po složkách (uživatel + cesta), kniha = celá složka od jednoho
člověka; stáhnou se všechny její zvukové soubory najednou."""

from __future__ import annotations

import hashlib
import json
import logging
import shutil
from collections import defaultdict
from pathlib import Path

import httpx

from app.providers import SlskdProvider, _seg
from app.redis_bus import get_redis

logger = logging.getLogger(__name__)

AUDIO = (".mp3", ".m4a", ".m4b", ".flac", ".ogg", ".opus", ".aac")
MIN_BOOK_BYTES = 30 * 1024 * 1024  # menší složka je spíš album / ukázka
_CACHE_TTL = 3600


def _ref(username: str, folder: str) -> str:
    # Do unikátního source_ref -- krátké a stabilní.
    return "slsk:" + hashlib.sha1(f"{username}\n{folder}".encode()).hexdigest()


def _title(folder: str) -> str:
    parts = [p for p in folder.replace("\\", "/").split("/") if p]
    tail = parts[-2:] if len(parts) >= 2 and len(parts[-1]) < 25 else parts[-1:]
    return " – ".join(tail) or folder


async def search(query: str) -> list[dict]:
    """Složky s audioknihou: nejdostupnější první (volný slot, rychlost),
    stejná složka u víc lidí jen jednou."""
    slskd = SlskdProvider()
    responses = await slskd.search_raw(query, cap_s=12)
    folders: dict[tuple[str, str], dict] = {}
    for r in responses:
        user = r["username"]
        groups: dict[str, list[dict]] = defaultdict(list)
        for f in r.get("files") or []:
            name = f.get("filename") or ""
            if name.lower().endswith(AUDIO):
                groups[name.replace("\\", "/").rsplit("/", 1)[0]].append(f)
        for folder, files in groups.items():
            size = sum(int(f.get("size") or 0) for f in files)
            if size < MIN_BOOK_BYTES:
                continue
            folders[(user, folder)] = {
                "user": user,
                "folder": folder,
                "files": [{"filename": f["filename"], "size": int(f.get("size") or 0)} for f in files],
                "size": size,
                "free": bool(r.get("hasFreeUploadSlot")),
                "speed": int(r.get("uploadSpeed") or 0),
                "queue": int(r.get("queueLength") or 0),
            }
    # Stejná kniha (stejné jméno složky a velikost) u víc lidí -> jedna
    # položka, nejlepší zdroj; počet lidí = dostupnost.
    best: dict[tuple[str, int], dict] = {}
    counts: dict[tuple[str, int], int] = defaultdict(int)
    for item in folders.values():
        key = (item["folder"].rsplit("/", 1)[-1].lower(), item["size"] // (1024 * 1024))
        counts[key] += 1
        cur = best.get(key)
        rank = (item["free"], item["speed"], -item["queue"])
        if cur is None or rank > (cur["free"], cur["speed"], -cur["queue"]):
            best[key] = item
    out = []
    r = get_redis()
    for key, item in best.items():
        ref = _ref(item["user"], item["folder"])
        await r.set(f"spoken:slsk:{ref}", json.dumps(item), ex=_CACHE_TTL)
        out.append({
            "source": "slskd",
            "ref": ref,
            "title": _title(item["folder"]),
            "sizeBytes": item["size"],
            "files": len(item["files"]),
            "seeders": counts[key],
            "freeSlot": item["free"],
        })
    out.sort(key=lambda x: (not x["freeSlot"], -x["seeders"], -x["sizeBytes"]))
    return out[:40]


async def cached(ref: str) -> dict | None:
    raw = await get_redis().get(f"spoken:slsk:{ref}")
    return json.loads(raw) if raw else None


async def start(user: str, files: list[dict]) -> None:
    slskd = SlskdProvider()
    async with httpx.AsyncClient(base_url=slskd.base_url, headers=slskd._headers(), timeout=20) as c:
        resp = await c.post(f"/api/v0/transfers/downloads/{_seg(user)}", json=files)
        if resp.status_code != 409:  # už ve frontě = navázat
            resp.raise_for_status()


# Kolikrát zkusit soubor znovu po přechodné chybě (uživatel chvíli offline,
# nespojilo se, vypršelo). Dřív jedna taková chyba shodila celou knihu, i když
# zbytek byl stažený nebo ve frontě (živě 7. 10.: Heir to the Empire 3/4).
MAX_ATTEMPTS = 3


def judge(transfers_by_file: dict[str, list[dict]], files: list[dict]) -> tuple[float, str, list[dict], str | None]:
    """(podíl, stav, soubory ke znovuzařazení, důvod selhání).
    Stav: downloading | done | retry | failed."""
    total = sum(f["size"] for f in files) or 1
    latest = {
        name: max(entries, key=lambda t: str(t.get("requestedAt", "")))
        for name, entries in transfers_by_file.items() if entries
    }
    if not latest:
        return 0.0, "failed", [], "Soulseek: stažení se nepodařilo zařadit, zkus jinou verzi"
    done = sum(int(t.get("bytesTransferred") or 0) for t in latest.values())
    retry: list[dict] = []
    for f in files:
        t = latest.get(f["filename"])
        state = str((t or {}).get("state") or "")
        if t is None or "Succeeded" in state or "Completed" not in state:
            continue
        if "Rejected" in state:
            return done / total, "failed", [], "Soulseek: uživatel tyhle soubory nesdílí, zkus jinou verzi"
        if len(transfers_by_file.get(f["filename"]) or []) >= MAX_ATTEMPTS:
            return done / total, "failed", [], "Soulseek: uživatel je nedostupný, zkus jinou verzi"
        retry.append(f)
    if retry:
        return min(done / total, 0.99), "retry", retry, None
    if len(latest) == len(files) and all("Succeeded" in str(t.get("state")) for t in latest.values()):
        return 1.0, "done", [], None
    return min(done / total, 0.99), "downloading", [], None


async def progress(user: str, files: list[dict]) -> tuple[float, str, list[dict], str | None]:
    """Viz `judge`; navíc 404 = slskd o stahování od uživatele neví."""
    slskd = SlskdProvider()
    wanted = {f["filename"] for f in files}
    async with httpx.AsyncClient(base_url=slskd.base_url, headers=slskd._headers(), timeout=20) as c:
        resp = await c.get(f"/api/v0/transfers/downloads/{_seg(user)}")
        if resp.status_code == 404:
            return 0.0, "failed", [], "Soulseek: stažení od tohoto uživatele se ztratilo, zkus jinou verzi"
        resp.raise_for_status()
        data = resp.json()
    # Všechny pokusy o každý soubor (počet = kolikrát už se zkoušel).
    by_file: dict[str, list[dict]] = defaultdict(list)
    for d in data.get("directories") or []:
        for t in d.get("files") or []:
            if t.get("filename") in wanted:
                by_file[t["filename"]].append(t)
    return judge(by_file, files)


async def collect(files: list[dict], dest: Path) -> int:
    """Stažené soubory ze složky slskd do složky knihy."""
    slskd = SlskdProvider()
    dest.mkdir(parents=True, exist_ok=True)
    moved = 0
    for f in files:
        remote = f["filename"].replace("/", "\\")
        basename = remote.rsplit("\\", 1)[-1]
        remote_dir = remote.rsplit("\\", 2)[-2] if remote.count("\\") >= 1 else ""
        found = await slskd._locate_with_retry(basename, remote_dir, 0.0, int(f.get("size") or 0))
        if found is None:
            continue
        target = dest / basename
        if not target.exists():
            shutil.move(str(found), target)
        moved += 1
    return moved
