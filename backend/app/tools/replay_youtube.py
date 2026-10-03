"""Nanečisto: co by nový výběr na YouTube vybral (jen hledání, nic se
nestahuje). Vzorek: skladby s ověřeně špatným souborem (přehled kontroly
stažených: mismatch/suspect) a náhodné správně stažené (délka sedí).

    python -m app.tools.replay_youtube [--bad N] [--good N]
"""

from __future__ import annotations

import random
import sys

from sqlmodel import Session, select

from app.db import engine
from app.library.download_check import read_report
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording
from app.providers import TrackMetadata, youtube_pick


def _track(s: Session, r: Recording) -> TrackMetadata:
    from app.worker import _album_title

    artist = s.get(Artist, r.artist_id) if r.artist_id else None
    return TrackMetadata(
        recording_id=r.id,
        title=r.title,
        artist_name=artist.name if artist else None,
        duration_ms=r.duration_ms,
        album_title=_album_title(s, r),
        isrc=r.isrc,
    )


def main(n_bad: int, n_good: int) -> None:
    report = read_report()
    rng = random.Random(7)
    with Session(engine) as s:
        bad_ids = [rid for rid, e in report.items() if e.get("verdict") in ("mismatch", "suspect")]
        rng.shuffle(bad_ids)
        good = []
        for r, a in s.exec(
            select(Recording, MediaAsset)
            .join(MediaAsset, MediaAsset.recording_id == Recording.id)
            .where(MediaAsset.status == MediaAssetStatus.AVAILABLE, MediaAsset.source_provider == "youtube")
        ).all():
            if r.duration_ms and a.waveform_duration_ms and abs(r.duration_ms - a.waveform_duration_ms) < 3000:
                good.append(r.id)
        rng.shuffle(good)
        sample = [("ŠPATNĚ", rid) for rid in bad_ids[:n_bad]] + [("DOBŘE", rid) for rid in good[:n_good]]
        tracks = [(kind, _track(s, s.get(Recording, rid))) for kind, rid in sample if s.get(Recording, rid)]
    stats: dict[str, int] = {}
    for kind, t in tracks:
        try:
            picks = youtube_pick(t, t.search_query)
            e = picks[0]
            res = f"[T{e['_tier']}] {e.get('title')} | {e.get('channel')} | {e.get('duration')}s"
            stats[f"{kind} vybráno"] = stats.get(f"{kind} vybráno", 0) + 1
        except Exception as exc:  # noqa: BLE001
            res = f"NEMÁME: {str(exc)[:110]}"
            stats[f"{kind} nemáme"] = stats.get(f"{kind} nemáme", 0) + 1
        print(f"{kind} | {t.artist_name} – {t.title} [{(t.duration_ms or 0) // 1000}s] -> {res}", flush=True)
    print(stats)


if __name__ == "__main__":
    args = sys.argv
    main(
        int(args[args.index("--bad") + 1]) if "--bad" in args else 45,
        int(args[args.index("--good") + 1]) if "--good" in args else 45,
    )
