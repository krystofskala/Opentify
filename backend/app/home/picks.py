"""„Tvoje výběry“ na Domů = jen připnuté věci profilu, v pořadí připnutí:

- `playlist:<id>` -- playlist (vlastní, mix, Oblíbené...),
- `album:<id>` -- album,
- `rail:<sekce>` -- chytrý seznam, který se generuje (Mix na teď, Tento
  týden před rokem, Méně známé skladby, Populární ve světě, Shazam,
  SoundCloud, rodina). Generuje se jen připnutý; na Domů je to karta
  playlistu `home:rail:<sekce>`.

Nahrazuje připínání do Rychlého výběru (`quick_pins:<user>`, jen playlisty);
staré připnutí se při prvním čtení převede (s chytrými seznamy, které profil
měl na Domů zapnuté).
"""

from __future__ import annotations

from sqlmodel import Session

from app.models import HomeSnapshot
from app.utils import utcnow

MAX_PINS = 24

# Chytré seznamy (dřív samostatné sekce se seznamem skladeb).
RAILS: dict[str, str] = {
    "now_mix": "Mix na teď",
    "year_ago": "Tento týden před rokem",
    "deep_cuts": "Méně známé skladby",
    "trending_tracks": "Populární ve světě",
    "shazam": "Z tvého Shazamu",
    "soundcloud": "Na SoundCloudu od tvých interpretů",
    "family": "Co poslouchá rodina",
}


def key(user_id: str) -> str:
    return f"quick_pins:{user_id}"


def get(session: Session, user_id: str) -> list[str]:
    row = session.get(HomeSnapshot, key(user_id))
    payload = (row.payload or {}) if row else {}
    if "items" in payload:
        return list(payload["items"])
    # Převod: chytré seznamy, které profil měl zapnuté, + playlisty
    # připnuté do Rychlého výběru.
    from app.home.service import effective_order, get_layout, is_visible

    layout = get_layout(session, user_id)
    rails = [f"rail:{sid}" for sid in effective_order(user_id, layout, include_rails=True) if sid in RAILS and is_visible(layout, sid)]
    items = rails + [f"playlist:{i}" for i in payload.get("ids") or []]
    return save(session, user_id, items)


def save(session: Session, user_id: str, items: list[str]) -> list[str]:
    items = list(dict.fromkeys(items))[:MAX_PINS]
    row = session.get(HomeSnapshot, key(user_id)) or HomeSnapshot(key=key(user_id))
    row.payload = {"items": items}
    row.generated_at = utcnow()
    session.add(row)
    session.commit()
    return items


def rail_of_source(source: str | None) -> str | None:
    """Playlist `home:rail:<id>` -> chytrý seznam (`family_<x>` patří k rodině)."""
    if not source or not source.startswith("home:rail:"):
        return None
    sid = source[len("home:rail:"):]
    return "family" if sid.startswith("family") else sid
