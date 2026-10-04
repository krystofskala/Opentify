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


def prefetch_recordings(session: Session, recording_ids: list[str]) -> list[object]:
    """Načte skladby, jejich interprety a soubory najednou (pár dotazů
    místo 3 na skladbu) -- další `session.get` je pak vezme z paměti session
    bez SQL. Oblíbené (517 skladeb): 1 553 dotazů / 532 ms -> 3 dotazy.

    Vrácený seznam drž v proměnné, dokud stavíš odpověď: session si objekty
    pamatuje jen slabě, bez odkazu by je mohla zahodit."""
    from sqlmodel import select

    from app.models import Recording

    keep: list[object] = []
    ids = list(dict.fromkeys(recording_ids))
    for i in range(0, len(ids), 500):
        chunk = ids[i : i + 500]
        recs = session.exec(select(Recording).where(Recording.id.in_(chunk))).all()  # type: ignore[attr-defined]
        keep.extend(recs)
        keep.extend(session.exec(select(MediaAsset).where(MediaAsset.recording_id.in_(chunk))).all())  # type: ignore[attr-defined]
        artist_ids = list({r.artist_id for r in recs if r.artist_id})
        for j in range(0, len(artist_ids), 500):
            keep.extend(session.exec(select(Artist).where(Artist.id.in_(artist_ids[j : j + 500]))).all())  # type: ignore[attr-defined]
    return keep


def recording_artist_name(session: Session, recording) -> str | None:
    """Jméno interpreta skladby -- u spolupráce celé ("Norman Blake & Tony
    Rice"), když skladba patří hlavnímu interpretovi alba, které má víc
    interpretů (`Release.external_refs.credits`). Jinak jako dřív."""
    from app.models import Release

    own = (recording.external_refs or {}).get("credits")
    if own and len(own) > 1:
        return "".join(f"{c['name']}{c.get('join') or ''}" for c in own).strip()
    if recording.release_id and recording.artist_id:
        release = session.get(Release, recording.release_id)
        credits = (release.external_refs or {}).get("credits") if release is not None else None
        if credits and release.artist_id == recording.artist_id and len(credits) > 1:
            return "".join(f"{c['name']}{c.get('join') or ''}" for c in credits).strip()
    return resolve_artist_name(session, recording.artist_id)


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
