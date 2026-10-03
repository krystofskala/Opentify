"""Jednorázové: opravy z ručního posouzení 80 souborů (agenti, 2026-10-03).

- KATALOG: správná délka / Deezer id (soubor je v pořádku, katalog ne).
- ZNOVU: soubor je jiná verze -> zdroj + otisk zakázat, soubor smazat,
  nastavit referenci přesné verze (dz id / délka) a stáhnout znovu.
- JUNK: pirátské vydání / video-only nahrávka -> skrýt, nestahovat, soubor smazat.

    python -m app.tools.apply_review_2026_10_03 [--dry-run]
"""

from __future__ import annotations

import asyncio
import sys
from pathlib import Path

from sqlmodel import Session, select

from app.db import engine
from app.models import MediaAsset, MediaAssetStatus, Recording, Release

# prefix id -> (délka s | None, deezer id | None)
KATALOG = {
    "9586e015": (192, "60839218"),     # Mňága -- Hodinový hotel (Made in Valmez)
    "fd0bf61e": (228, "3410672871"),   # twenty one pilots -- The Contract
    "e66543e2": (None, "1105737"),     # Nirvana -- Pennyroyal Tea (Unplugged)
    "0b046f7a": (217, "6581143"),      # Paul Simon -- 50 Ways
    "376bd95d": (175, "1105744"),      # Nirvana -- Lake of Fire (Unplugged)
    "351f70d9": (None, "543970322"),   # WSTR -- Crisis
    "4e22b64a": (None, "373479341"),   # Brooklyn Duo -- Bohemian Rhapsody
    "5b221165": (None, "3601337102"),  # Barbora Poláková -- drak
    "922a148d": (None, "1833142047"),  # Rachel Sermanni -- Tractor
    "bcda0b32": (None, "1105733"),     # Nirvana -- About a Girl (Unplugged)
}
ZNOVU = {
    "93158f88": (220, None),           # Pennyroyal Tea (Unplugged, druhý řádek)
    "9a968b27": (None, None),          # Queen -- Good Old-Fashioned Lover Boy (dostal TOTP live)
    "a28a4f98": (261, "1558640882"),   # Mulberry Street (Livestream Version)
    "c691ab59": (261, "4209881432"),   # Ride (Live In Mexico City)
    "c931b907": (267, "3497126261"),   # Vypsaná fiXa -- 1982 (verze 98)
    "d01f0bd9": (288, "4091933791"),   # Queen -- Tie Your Mother Down (studio)
    "ae21ef22": (None, None),          # Rachel Sermanni -- Lay-Oh
    "097698bb": (172, "1105738"),      # Nirvana -- Dumb (Unplugged)
    "53539691": (196, "1105739"),      # Nirvana -- Polly (Unplugged)
    "5c88b272": (254, "1105734"),      # Nirvana -- Come as You Are (Unplugged)
    "59e6d759": (260, "1105736"),      # Nirvana -- The Man Who Sold the World (useknutý)
    "2c1988e6": (168, "3497126221"),   # Vypsaná fiXa -- Lunapark (verze 98)
    "52228753": (388, "4180099232"),   # Rachel Sermanni -- Strange Death
    "6c63362b": (287, "3497126191"),   # Vypsaná fiXa -- Potápěči (verze 98)
    "891ff602": (212, "3497126251"),   # Vypsaná fiXa -- Letní tlení (verze 98)
    "7799bbe6": (122, "1120336052"),   # Hisaishi -- 湯屋の朝
    "77e7c0fe": (63, "1120335032"),    # Hisaishi -- 春のめぐり
    "7e64d0c9": (88, "1120340962"),    # Hisaishi -- 雨の中で
    "281e7806": (None, None),          # Kalandra -- Špitál u Sv. Jakuba (Blues Session)
    "5ee2f22d": (None, None),          # Kalandra -- Dům z obilí (Blues Session)
    "496770b4": (None, None),          # Watchhouse -- Turtle Dove (Folkadelphia Session)
    "7a6ade86": (None, None),          # Jesse Welles -- The Poor
    "ee01a6a4": (None, None),          # Vypsaná fiXa -- Krabice (1994)
    "9fe4974a": (None, None),          # (nahrazeno junk níž, ponecháno pro jistotu)
}
# Pirátská vydání: celé vydání skrýt (podle nahrávky na něm).
JUNK_RELEASE_OF = [
    "c1fb2b9b", "c86d1716", "cef8ebb2", "d5cfb8b4", "f08a48f4", "082d8df6", "0b02c141", "0cfdcfe9", "1565a50f",
    "6087de88", "747c3274",                                    # "The Beatles Unpublished-披头士珍藏版"
    "b137ebd9",                                                # Star Man -- mashup mixtape
    "9fe4974a", "e099a58e", "f79bb826", "551087c9",            # Neil Young -- koncertní bootlegy
    "ccd33a13", "4341573a",                                    # twenty one pilots -- Voodoo Fest 2014
]
JUNK_RECORDING = ["a39bce88"]  # Nirvana -- "Interlude" (jen video, soubor = srbský rap)
ZNOVU.pop("9fe4974a")


def _rec(session: Session, prefix: str) -> Recording | None:
    return session.exec(select(Recording).where(Recording.id.like(f"{prefix}%"))).first()  # type: ignore[attr-defined]


def _set_ref(session: Session, rec: Recording, secs: int | None, dz: str | None) -> str:
    notes = []
    if secs:
        rec.duration_ms = secs * 1000
        notes.append(f"délka {secs}")
    if dz and rec.deezer_id != dz:
        taken = session.exec(select(Recording.id).where(Recording.deezer_id == dz, Recording.id != rec.id)).first()
        if taken is None:
            rec.deezer_id = dz
            notes.append(f"dz {dz}")
        else:
            notes.append(f"dz {dz} už má {taken[:8]}")
    session.add(rec)
    return ", ".join(notes)


def _drop_file(session: Session, rec: Recording) -> None:
    asset = session.get(MediaAsset, rec.id)
    if asset is None:
        return
    if asset.storage_path and Path(asset.storage_path).resolve().is_relative_to(Path("/data/media")):
        Path(asset.storage_path).unlink(missing_ok=True)
    asset.status = MediaAssetStatus.MISSING
    asset.storage_path = None
    session.add(asset)


async def main(dry: bool) -> None:
    from app.auth import ADMIN_ID
    from app.library.verify_file import signature
    from app.provisioning_service import get_or_create_job
    from app.redis_bus import PROVISIONING_STREAM, get_redis

    job_ids: list[str] = []
    with Session(engine) as s:
        for prefix, (secs, dz) in KATALOG.items():
            rec = _rec(s, prefix)
            print(f"KATALOG {rec.title if rec else prefix}: {'' if dry or rec is None else _set_ref(s, rec, secs, dz)}")
        if not dry:
            s.commit()

    for prefix, (secs, dz) in ZNOVU.items():
        with Session(engine) as s:
            rec = _rec(s, prefix)
            asset = s.get(MediaAsset, rec.id) if rec else None
            if rec is None:
                print(f"ZNOVU {prefix}: nenalezeno")
                continue
            path = Path(asset.storage_path) if asset and asset.storage_path else None
            print(f"ZNOVU {rec.title} ({asset.status if asset else None})")
            if dry:
                continue
        fp = await signature(path) if path and path.exists() else None
        with Session(engine) as s:
            rec = s.get(Recording, rec.id)
            refs = dict(rec.external_refs or {})
            key = refs.get("sourceKey")
            if not key and refs.get("youtubeUrl"):
                key = f"youtube:{str(refs['youtubeUrl']).rsplit('=', 1)[-1]}"
            if key:
                refs["rejectedSources"] = [*[k for k in refs.get("rejectedSources") or [] if k != key], key]
            if fp:
                refs["rejectedFingerprints"] = [*(refs.get("rejectedFingerprints") or [])[-4:], fp]
            refs.pop("sourceKey", None)
            refs.pop("youtubeUrl", None)
            rec.external_refs = refs
            print("   ", _set_ref(s, rec, secs, dz))
            _drop_file(s, rec)
            s.commit()
            _a, job, created = get_or_create_job(s, rec.id, ADMIN_ID, None)
            if job is not None and created:
                job_ids.append(job.id)

    with Session(engine) as s:
        releases: set[str] = set()
        for prefix in JUNK_RELEASE_OF:
            rec = _rec(s, prefix)
            if rec is None or not rec.release_id:
                continue
            if rec.release_id not in releases:
                rel = s.get(Release, rec.release_id)
                print(f"JUNK vydání: {rel.title if rel else rec.release_id}")
                if not dry and rel is not None:
                    rel.external_refs = {**(rel.external_refs or {}), "junk": True}
                    s.add(rel)
                releases.add(rec.release_id)
            if not dry:
                _drop_file(s, rec)
        for prefix in JUNK_RECORDING:
            rec = _rec(s, prefix)
            if rec is None:
                continue
            print(f"JUNK nahrávka: {rec.title}")
            if not dry:
                rec.external_refs = {**(rec.external_refs or {}), "junk": True}
                s.add(rec)
                _drop_file(s, rec)
        if not dry:
            s.commit()
            # Ostatní stažené soubory na skrytých vydáních taky pryč.
            for rid in releases:
                for rec in s.exec(select(Recording).where(Recording.release_id == rid)).all():
                    asset = s.get(MediaAsset, rec.id)
                    if asset is not None and asset.status == MediaAssetStatus.AVAILABLE:
                        print(f"   soubor pryč: {rec.title}")
                        _drop_file(s, rec)
            s.commit()

    r = get_redis()
    for jid in job_ids:
        await r.xadd(PROVISIONING_STREAM, {"job_id": jid})
    print(f"hotovo, znovu stahuji {len(job_ids)}")


if __name__ == "__main__":
    asyncio.run(main("--dry-run" in sys.argv))
