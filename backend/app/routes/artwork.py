"""Obaly vytažené z lokálních souborů (viz `catalog/embedded_art.py`)."""

from __future__ import annotations

import re

from fastapi import APIRouter, HTTPException
from fastapi.responses import FileResponse

from app.catalog.embedded_art import artwork_path, artwork_png_path

artwork_router = APIRouter(prefix="/artwork", tags=["artwork"])

_ID_RE = re.compile(r"^[0-9a-fA-F-]{36}$")


@artwork_router.get("/releases/{release_id}")
def release_artwork(release_id: str) -> FileResponse:
    # Jen UUID -- ID jde rovnou do cesty na disku.
    if not _ID_RE.match(release_id):
        raise HTTPException(status_code=404)
    # Vlastní obal playlistu s průhledností je PNG.
    path, media_type = artwork_png_path(release_id), "image/png"
    if not path.exists():
        path, media_type = artwork_path(release_id), "image/jpeg"
    if not path.exists():
        raise HTTPException(status_code=404)
    return FileResponse(
        path,
        media_type=media_type,
        headers={"Cache-Control": "public, max-age=604800, immutable"},
    )
