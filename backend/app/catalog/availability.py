"""Mapování `Recording` (katalogová entita) -> `availability` příznak podle
lokální `MediaAsset` tabulky. Jde o jediné místo, kde se tahle logika počítá,
protože se používá na čtyřech různých endpointech (search, tracklist,
recommendations, provisioning)."""

from __future__ import annotations

from sqlmodel import Session

from app.catalog.schemas import Availability
from app.models import Artist, MediaAsset, MediaAssetStatus


def compute_availability(session: Session, recording_id: str) -> Availability:
    """`available`      -> MediaAsset.status == AVAILABLE, lze rovnou streamovat.
    `provisionable` -> nahrávka je v našem lokálním katalogu (Catalog Service
        ji tam upsertnul při search/browse), takže na ni jde zavolat
        `POST /tracks/{id}/provision`.

    `unavailable` v této fázi nenastává: jakmile Catalog Service entitu vidí a
    zapíše, umí pro ni založit provisioning job (viz app/provisioning_service.py).
    Reálné rozlišení "žádný známý zdroj" přijde až s konkrétní produkční
    implementací `MediaProvider.resolve()` (app/providers.py), která dokáže
    řekout "tohle nikde nenajdu" — architektura na to místo má, sketch ho
    ale nevyplňuje.
    """
    asset = session.get(MediaAsset, recording_id)
    if asset is not None and asset.status == MediaAssetStatus.AVAILABLE:
        return Availability.AVAILABLE
    return Availability.PROVISIONABLE


def resolve_artist_name(session: Session, artist_id: str | None) -> str | None:
    """`RecordingOut.artist_name` -- denormalizovaný jméno interpreta přímo
    v odpovědi. Bez tohohle by klient u smíšených seznamů (Domů, Knihovna,
    Oblíbené, playlisty -- kdekoliv skladby NEJSOU ze stejného alba/interpreta)
    neměl odkud jméno vzít, jen `artist_id` -- živě nahlášeno jako "všude
    chybí interpret". Sdílené místo stejně jako `compute_availability` výš,
    ze stejného důvodu (používá se na všech stejných endpointech)."""
    if artist_id is None:
        return None
    artist = session.get(Artist, artist_id)
    return artist.name if artist is not None else None
