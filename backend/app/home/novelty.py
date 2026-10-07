"""Jeden filtr NOVÝCH skladeb pro všechny mixy (audit 7. 10. po změnách,
chyby 3 a 5). Dřív ho úplně měly jen Pusť teď a Objevy týdne; Denní mixy,
mixy žánrů, Mix na teď a Tvůj mix · styl kontrolovaly "už slyšené" jen podle
id (známá skladba z importu s jiným id se vracela jako "nová") a "míň
takových" neznaly.

Nová skladba projde, jen když:
- ji profil neslyšel (ani pod jiným id: interpret + název bez verzí),
- interpret není "nelíbí se" ani "míň takových", skladba není "nelíbí se",
- není 2x přeskočená (appka 90 dní, import v kontextu algoritmu 180 dní),
- nemá pauzu "nabídnuto, nepuštěno" (app/home/repetition.py).
"""

from __future__ import annotations

from sqlmodel import Session, select

from app.db import engine


def filter_new(user_id: str, recording_ids: list[str], act=None) -> list[str]:
    from datetime import timedelta

    from app.catalog.availability import recording_artist_name
    from app.home import activation as av
    from app.home import repetition
    from app.home.feedback import deltas, fit_multiplier
    from app.library.dislikes import disliked_artist_ids, disliked_ids
    from app.models import Recording, SkipStreak
    from app.utils import utcnow

    ids = list(dict.fromkeys(r for r in recording_ids if r))
    if not ids:
        return []
    act = act if act is not None else av.cached(user_id)
    muted = {a for a, d in deltas(user_id).items() if fit_multiplier(d) < 1}
    paused, _muted_offers = repetition.ignored_offers(user_id)
    skipped = repetition.imported_skips(user_id)
    with Session(engine) as session:
        banned = disliked_artist_ids(session, user_id) | muted
        bad_tracks = disliked_ids(session, user_id)
        skipped |= set(
            session.exec(
                select(SkipStreak.recording_id).where(
                    SkipStreak.user_id == user_id,
                    SkipStreak.streak >= 2,
                    SkipStreak.updated_at >= (utcnow() - timedelta(days=90)).replace(tzinfo=None),
                )
            ).all()
        )
        recs = {
            r.id: r for r in session.exec(select(Recording).where(Recording.id.in_(ids))).all()  # type: ignore[attr-defined]
        }
        out = []
        for rid in ids:
            rec = recs.get(rid)
            if rec is None or rid in act.total or rid in bad_tracks or rid in skipped or rid in paused:
                continue
            if rec.artist_id in banned:
                continue
            if av.track_key(recording_artist_name(session, rec) or "", rec.title or "") in act.heard_keys:
                continue
            out.append(rid)
    return out
