"""Kanonický tracklist alba a jeho vazba na starší řádky.

`album_recordings` -- "skladby alba" pro operace nad celým albem (stáhnout,
přidat do knihovny, rádio, Dokonči album): tracklist kanonické edice, ne
řádky z jiných edic (`otherEdition`), které u alba visí jen kvůli hledání.

`find_referenced_twin` / `adopt_mbid` -- když se kanonická edice změní,
nové MB nahrávky nesmí založit nové řádky vedle starých se staženým
souborem / poslechy / lajky (pak soubor "zmizel" z alba). Starý řádek
převezme nové MBID; sloučí se jen opravdu táž skladba (stejný název
včetně verze a délka ±3 s)."""
from __future__ import annotations

from sqlmodel import Session, select

from app.models import LibraryEntry, Listen, ListenLater, MediaAsset, MediaAssetStatus, PlaylistItem, Recording, Release

TOLERANCE_MS = 3000


def is_other_edition(rec: Recording) -> bool:
    return bool((rec.external_refs or {}).get("otherEdition"))


def album_recordings(session: Session, release: Release | str) -> list[Recording]:
    """Skladby kanonického tracklistu (pořadí `tracklistIds`), jinak řádky
    alba bez skladeb z jiných edic."""
    if isinstance(release, str):
        release = session.get(Release, release)
        if release is None:
            return []
    ids = (release.external_refs or {}).get("tracklistIds") or []
    if ids:
        rows = {r.id: r for r in session.exec(select(Recording).where(Recording.id.in_(ids))).all()}  # type: ignore[attr-defined]
        if rows:
            return [rows[i] for i in ids if i in rows]
    recs = [r for r in session.exec(select(Recording).where(Recording.release_id == release.id)).all() if not is_other_edition(r)]
    recs.sort(key=lambda r: (r.track_number is None, r.track_number or 0, r.title))
    return recs


def has_refs(session: Session, rec_id: str) -> bool:
    """Na řádek něco odkazuje (stažený soubor, poslech, playlist/lajk,
    knihovna, Poslechnout později) -- takový se nesmí ztratit z alba."""
    asset = session.get(MediaAsset, rec_id)
    if asset is not None and asset.status == MediaAssetStatus.AVAILABLE:
        return True
    for column in (Listen.recording_id, PlaylistItem.recording_id, LibraryEntry.recording_id):
        if session.exec(select(column).where(column == rec_id).limit(1)).first() is not None:
            return True
    return session.exec(
        select(ListenLater.id).where(ListenLater.kind == "track", ListenLater.target_id == rec_id).limit(1)
    ).first() is not None


def has_file(session: Session, rec_id: str) -> bool:
    asset = session.get(MediaAsset, rec_id)
    return asset is not None and asset.status == MediaAssetStatus.AVAILABLE


def effective_duration(session: Session, rec: Recording) -> int | None:
    """Délka staženého souboru, je-li známá -- MBID starého řádku bývá
    špatně (živě: Sigh No More měl MBID živé verze, soubor je studiový)."""
    asset = session.get(MediaAsset, rec.id)
    if asset is not None and asset.status == MediaAssetStatus.AVAILABLE and asset.waveform_duration_ms:
        return asset.waveform_duration_ms
    return rec.duration_ms


def compatible(duration_ms: int | None, track_number: int | None, twin: Recording, twin_duration: int | None) -> bool:
    """Délky známe obě -> ±3 s (explicit/clean, live/studio se jinak
    neslučují); jinak aspoň stejné číslo stopy."""
    if duration_ms and twin_duration:
        return abs(duration_ms - twin_duration) <= TOLERANCE_MS
    return track_number is not None and twin.track_number == track_number


def find_referenced_twin(
    session: Session,
    candidates: list[Recording],
    title: str,
    duration_ms: int | None,
    track_number: int | None,
    exclude: set[str],
) -> Recording | None:
    """Starý řádek téže skladby téhož alba, na který něco odkazuje.
    Se staženým souborem napřed."""
    from app.maintenance.dedupe import track_key

    key = track_key(title)
    found = [
        r for r in candidates
        if r.id not in exclude
        and track_key(r.title) == key
        and compatible(duration_ms, track_number, r, effective_duration(session, r))
        and has_refs(session, r.id)
    ]
    if not found:
        found = [r for r in candidates if r.id not in exclude and _loose_file_twin(session, r, title, duration_ms)]
    found.sort(key=lambda r: (not has_file(session, r.id), is_other_edition(r)))
    return found[0] if found else None


def _loose_file_twin(session: Session, rec: Recording, title: str, duration_ms: int | None) -> bool:
    """Stažený soubor, jehož název z tagů se liší jen překlepem nebo
    doplňkem ("Tanguska" / "Tunguska", "Come Together (Remastered 2009)",
    "Wolfcreek Pass (Great)"). Jen se souborem, jen se známou délkou obou
    (±3 s) a jen se stejnými slovy verze -- "(Acoustic)" / "(Live at...)"
    je jiná nahrávka a zůstává zvlášť. Jinak by "stáhnout album" stahovalo
    tutéž skladbu znovu a soubor visel mimo tracklist."""
    from difflib import SequenceMatcher

    from app.download_match import core_title, fold
    from app.tools.fix_merged_versions import _versions

    if not duration_ms or not has_file(session, rec.id):
        return False
    other = effective_duration(session, rec)
    if not other or abs(other - duration_ms) > TOLERANCE_MS:
        return False
    if _versions(rec.title or "") != _versions(title or ""):
        return False
    a, b = fold(core_title(rec.title or "")).strip(), fold(core_title(title or "")).strip()
    return bool(a and b) and SequenceMatcher(None, a, b).ratio() >= 0.85


def adopt_mbid(session: Session, twin: Recording, mbid: str) -> None:
    """`twin` převezme `mbid`. Řádek, který ho dosud měl (nová kopie téže
    skladby), se do něj sloučí i se vším, co na něj odkazuje. Staré MBID
    se uvolní -- je-li to jiná nahrávka (živá verze z jiné edice), založí
    ji příští načtení jako skladbu z jiné edice, nic se neztratí."""
    from app.maintenance.dedupe import merge_recording

    holder = session.exec(select(Recording).where(Recording.mbid == mbid)).first()
    twin.mbid = None
    session.add(twin)
    session.flush()
    if holder is not None and holder.id != twin.id:
        holder.mbid = None  # unikátní MBID -- uvolnit před sloučením
        session.add(holder)
        session.flush()
        merge_recording(session, holder, twin)
    twin.mbid = mbid
    # Poznámka/edice staré nahrávky k novému MBID nepatří.
    twin.external_refs = {
        k: v for k, v in (twin.external_refs or {}).items() if k not in ("otherEdition", "mbDisambiguation")
    }
    session.add(twin)
    session.flush()
