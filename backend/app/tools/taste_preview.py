"""Před/po: původní model vkusu (v1) vs nový (v2) pro jeden profil.
Jen čte a vypíše markdown; žádné playlisty se neukládají.

    python -m app.tools.taste_preview <user_id>
"""

from __future__ import annotations

import os
import random
import sys

from sqlmodel import Session

from app.catalog.availability import recording_artist_name
from app.db import engine
from app.home import personal_mixes as pm
from app.models import Recording


def _label(session: Session, rid: str) -> str:
    rec = session.get(Recording, rid)
    if rec is None:
        return rid[:8]
    return f"{recording_artist_name(session, rec) or '?'} – {rec.title}"


def _throwback_v1(taste) -> list[str]:
    from datetime import timedelta

    from app.utils import utcnow

    now = utcnow()
    cands = [
        r for r in dict.fromkeys(list(taste.liked) + list(taste.listen_counts))
        if r not in taste.last_played or now - taste.last_played[r] >= timedelta(days=90)
    ]
    played = [r for r in cands if r in taste.listen_counts]
    random.Random(1).shuffle(played)
    return pm._cap_per_artist(played, taste.artist_of, 2)[:15]


def main() -> None:
    user_id = sys.argv[1] if len(sys.argv) > 1 else "demo-user"
    os.environ["TASTE_MODEL"] = "v1"
    v1 = pm.load_taste(user_id)
    os.environ["TASTE_MODEL"] = "v2"
    v2 = pm.load_taste(user_id)
    rng = random.Random(1)
    out = [f"# Vkus před/po – {user_id}", ""]
    with Session(engine) as session:
        out += ["## Top 25 interpretů", "", "| # | dnes (365 dní) | nový (celá historie + měsíce + teď) |", "|---|---|---|"]
        a1 = [v1.artist_name.get(a, a[:8]) for a, _ in v1.artist_weight.most_common(25)]
        a2 = [v2.artist_name.get(a, a[:8]) for a, _ in v2.artist_weight.most_common(25)]
        for i in range(25):
            out.append(f"| {i + 1} | {a1[i] if i < len(a1) else ''} | {a2[i] if i < len(a2) else ''} |")
        out += ["", "## Návrat do minulosti (ukázka 15)", "", "**dnes:** náhodně z čehokoli, co jsi 90 dní neslyšel", ""]
        out += [f"- {_label(session, r)}" for r in _throwback_v1(v1)]
        loves = [r for r in v2.activation.former_loves() if r in v2.artist_of][:150]
        tb2 = pm._cap_per_artist(pm._weighted_order(loves, lambda r: v2.activation.peak.get(r, 1), rng), v2.artist_of, 2)[:15]
        out += ["", "**nový:** „bývalé lásky“ – kdysi hrané hodně, teď potichu", ""]
        out += [f"- {_label(session, r)}" for r in tb2]
        liked_or_played = list(set(v2.liked) | set(v2.listen_counts))
        fam1 = list(set(v1.liked) | set(v1.listen_counts))
        random.Random(2).shuffle(fam1)
        fam2 = pm._weighted_order(liked_or_played, lambda r: v2.track_score(r), random.Random(2))
        out += ["", "## Známé skladby do Denních mixů (ukázka 15)", "", "**dnes:** náhodně ze všeho slyšeného za rok", ""]
        out += [f"- {_label(session, r)}" for r in pm._cap_per_artist(fam1, v1.artist_of, 2)[:15]]
        out += ["", "**nový:** vážené podle toho, jak moc skladba teď „žije“", ""]
        out += [f"- {_label(session, r)}" for r in pm._cap_per_artist(fam2, v2.artist_of, 2)[:15]]
    print("\n".join(out))


if __name__ == "__main__":
    main()
