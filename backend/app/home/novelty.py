"""Jeden filtr NOVÝCH skladeb pro všechny mixy (audit 7. 10. po změnách,
chyby 3 a 5). Dřív ho úplně měly jen Pusť teď a Objevy týdne; Denní mixy,
mixy žánrů, Mix na teď a Tvůj mix · styl kontrolovaly "už slyšené" jen podle
id (známá skladba z importu s jiným id se vracela jako "nová") a "míň
takových" neznaly.

Nová skladba projde, jen když:
- ji profil neslyšel (ani pod jiným id: interpret + název bez verzí),
- interpret není "nelíbí se" ani "míň takových", skladba není "nelíbí se",
- není 2x přeskočená (appka 90 dní, import v kontextu algoritmu 180 dní),
- nemá pauzu "nabídnuto, nepuštěno" (app/home/repetition.py),
- není karaoke / napodobenina / slowed apod.
Od 22. 10. (OP-ALG1) jsou pravidla v app/home/guard.py, společná i pro známé.
"""

from __future__ import annotations

from sqlmodel import Session, select

from app.db import engine


def filter_new(user_id: str, recording_ids: list[str], act=None, guard=None) -> list[str]:
    """Pravidla v app/home/guard.py (jedna sada pro všechna skládání)."""
    from app.catalog.availability import recording_artist_name
    from app.home import activation as av
    from app.home import guard as gd
    from app.models import Recording

    ids = list(dict.fromkeys(r for r in recording_ids if r))
    if not ids:
        return []
    act = act if act is not None else av.cached(user_id)
    with Session(engine) as session:
        guard = guard if guard is not None else gd.load(user_id, session)
        recs = {
            r.id: r for r in session.exec(select(Recording).where(Recording.id.in_(ids))).all()  # type: ignore[attr-defined]
        }
        out = []
        for rid in ids:
            rec = recs.get(rid)
            if rec is None or rid in act.total or not guard.allowed(rid, rec.artist_id, new=True):
                continue
            artist = recording_artist_name(session, rec) or ""
            if gd.is_junk(rec.title, artist) or av.track_key(artist, rec.title or "") in act.heard_keys:
                continue
            out.append(rid)
    return out
