"""Obal alba vytažený přímo z lokálních audio souborů -- poslední záchrana pro
alba z knihovny, pro která Cover Art Archive ani Deezer nic nemají (typicky
kompilace, bootlegy, domácí rips). Obal se zmenší na ≤600 px JPEG a uloží na
media volume; servíruje ho `routes/artwork.py`."""

from __future__ import annotations

import base64
import io
import logging
from pathlib import Path

from mutagen import File as MutagenFile
from mutagen.flac import Picture
from sqlmodel import Session, select

from app.db import engine
from app.models import MediaAsset, MediaAssetStatus, Recording

logger = logging.getLogger(__name__)

ARTWORK_DIR = Path("/data/media/artwork")
MAX_SIDE = 600
# Relativní -- klient ji skládá proti své API base URL (funguje přes IP i
# přes HTTPS adresu z `tailscale serve`, backend neví, kudy klient přišel).
URL_TEMPLATE = "/api/v1/artwork/releases/{release_id}"


def artwork_path(release_id: str) -> Path:
    return ARTWORK_DIR / f"{release_id}.jpg"


def artwork_png_path(release_id: str) -> Path:
    """Vlastní obal playlistu s průhledností (PNG) -- má přednost před .jpg."""
    return ARTWORK_DIR / f"{release_id}.png"


def save_custom_cover(data: bytes, release_id: str, max_side: int = MAX_SIDE) -> bool:
    """Nahraný obal playlistu: s průhlednými pixely jako PNG (průhlednost
    zůstane), jinak JPEG jako ostatní obaly. Druhý formát se smaže."""
    from PIL import Image

    try:
        with Image.open(io.BytesIO(data)) as img:
            img.load()
            if min(img.size) < 64:
                return False
            has_alpha = img.mode in ("RGBA", "LA") or (img.mode == "P" and "transparency" in img.info)
            if has_alpha:
                rgba = img.convert("RGBA")
                lo, _hi = rgba.getchannel("A").getextrema()
                if lo < 255:
                    rgba.thumbnail((max_side, max_side))
                    dest = artwork_png_path(release_id)
                    dest.parent.mkdir(parents=True, exist_ok=True)
                    tmp = dest.with_suffix(".tmp")
                    rgba.save(tmp, "PNG", optimize=True)
                    tmp.replace(dest)
                    artwork_path(release_id).unlink(missing_ok=True)
                    return True
    except Exception:  # noqa: BLE001 - neplatná/nepodporovaná data
        return False
    if not _save_resized(data, artwork_path(release_id), max_side):
        return False
    artwork_png_path(release_id).unlink(missing_ok=True)
    return True


def _picture_bytes(path: str) -> bytes | None:
    try:
        audio = MutagenFile(path)
    except Exception:  # noqa: BLE001 - poškozený/neznámý soubor
        return None
    if audio is None:
        return None

    pictures = getattr(audio, "pictures", None)  # FLAC
    if pictures:
        return pictures[0].data

    tags = audio.tags
    if tags is None:
        return None
    # ID3 (MP3/AIFF/WAV): APIC:*, přednostně přední obal (type 3).
    if hasattr(tags, "getall"):
        apics = tags.getall("APIC")
        if apics:
            front = next((a for a in apics if getattr(a, "type", None) == 3), apics[0])
            return front.data
    try:
        keys = list(tags.keys())
    except Exception:  # noqa: BLE001
        return None
    if "covr" in keys and tags["covr"]:  # MP4/M4A
        return bytes(tags["covr"][0])
    for key in ("WM/Picture",):  # ASF/WMA
        if key in keys and tags[key]:
            value = tags[key][0].value
            # WM/Picture: typ (1 B) + délka (4 B) + MIME a popis (UTF-16, \0\0) + data
            try:
                offset = 5
                for _ in range(2):
                    end = value.index(b"\x00\x00", offset)
                    while (end - offset) % 2:
                        end = value.index(b"\x00\x00", end + 1)
                    offset = end + 2
                return value[offset:]
            except ValueError:
                return None
    for key in ("metadata_block_picture", "METADATA_BLOCK_PICTURE"):  # Ogg Vorbis/Opus
        if key in keys and tags[key]:
            try:
                return Picture(base64.b64decode(tags[key][0])).data
            except Exception:  # noqa: BLE001
                return None
    return None


def _save_resized(data: bytes, dest: Path, max_side: int = MAX_SIDE) -> bool:
    from PIL import Image

    try:
        with Image.open(io.BytesIO(data)) as img:
            img = img.convert("RGB")
            if min(img.size) < 64:
                return False  # ikonka/placeholder, ne obal
            img.thumbnail((max_side, max_side))
            dest.parent.mkdir(parents=True, exist_ok=True)
            tmp = dest.with_suffix(".tmp")
            img.save(tmp, "JPEG", quality=88, optimize=True)
            tmp.replace(dest)
            return True
    except Exception:  # noqa: BLE001 - neplatná/nepodporovaná data
        return False


def _local_files(release_id: str) -> list[str]:
    with Session(engine) as session:
        return [
            p
            for p in session.exec(
                select(MediaAsset.storage_path)
                .join(Recording, Recording.id == MediaAsset.recording_id)
                .where(Recording.release_id == release_id, MediaAsset.status == MediaAssetStatus.AVAILABLE)
            ).all()
            if p
        ]


def extract_release_art(release_id: str) -> str | None:
    """Sync (volat přes `asyncio.to_thread`). Vrátí relativní URL, když se
    obal podařilo vytáhnout a uložit, jinak `None`."""
    dest = artwork_path(release_id)
    if dest.exists():
        return URL_TEMPLATE.format(release_id=release_id)
    for path in _local_files(release_id)[:5]:
        data = _picture_bytes(path)
        if data and _save_resized(data, dest):
            return URL_TEMPLATE.format(release_id=release_id)
    return None
