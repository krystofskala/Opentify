"""Domů mluveného slova: pořadí a viditelnost sekcí podle profilu, stejně
jako u hudebního Domů (`app/home/service.py` -- `get_layout`,
`effective_order`). Sekce kreslí appka sama z dat, která už má (knihy,
podcasty, doporučení); server jen pamatuje, co si profil nastavil.

Uloženo v `HomeSnapshot` `spoken_layout:<profil>` = {order, visible}.
"""

from __future__ import annotations

from typing import Any

from sqlmodel import Session

from app.db import engine
from app.models import HomeSnapshot
from app.utils import utcnow

# Výchozí pořadí. Vlastní sekce (Tvoje knihy, Tvoje pořady, Stahuje se) se
# ukážou, až v nich něco je -- nový profil tak vidí jen základ: Pokračovat,
# Nové díly, doporučení a knihy, které už na serveru jsou (uživatel 7. 10.:
# „audioknihy ostatních ve vlastní sekci, ušetří to stahování“).
SECTIONS: list[tuple[str, str]] = [
    ("continue", "Pokračovat"),
    ("new_episodes", "Nové díly"),
    ("my_books", "Tvoje knihy"),
    ("shows", "Tvoje pořady"),
    ("rec_books", "Doporučené knihy"),
    ("rec_podcasts", "Doporučené podcasty"),
    ("others_books", "Knihy ostatních"),
    ("downloading", "Stahuje se"),
]
# Nové sekce, které by časem přibyly, si profil zapne sám.
DEFAULT_OFF: set[str] = set()


def layout_key(user_id: str) -> str:
    return f"spoken_layout:{user_id}"


def get_layout(session: Session, user_id: str) -> dict[str, Any]:
    row = session.get(HomeSnapshot, layout_key(user_id))
    payload = (row.payload or {}) if row else {}
    return {"order": list(payload.get("order") or []), "visible": dict(payload.get("visible") or {})}


def effective_order(layout: dict[str, Any]) -> list[str]:
    """Uložené pořadí + sekce, které v něm nejsou (nové), za svého výchozího
    předchůdce -- stejně jako `app.home.service.effective_order`."""
    defaults = [sid for sid, _t in SECTIONS]
    order = [sid for sid in layout["order"] if sid in defaults]
    if not order:
        return defaults
    for i, sid in enumerate(defaults):
        if sid in order:
            continue
        prev = next((defaults[j] for j in range(i - 1, -1, -1) if defaults[j] in order), None)
        order.insert(order.index(prev) + 1 if prev else 0, sid)
    return order


def entries(user_id: str) -> list[dict[str, Any]]:
    """Sekce v pořadí profilu i se skrytými (Upravit Domů)."""
    titles = dict(SECTIONS)
    with Session(engine) as session:
        layout = get_layout(session, user_id)
    return [
        {"id": sid, "title": titles[sid], "visible": bool(layout["visible"].get(sid, sid not in DEFAULT_OFF))}
        for sid in effective_order(layout)
    ]


def save(user_id: str, order: list[str], hidden: list[str]) -> list[dict[str, Any]]:
    """Prázdné pořadí = Výchozí (vše zpět)."""
    known = {sid for sid, _t in SECTIONS}
    order = [sid for sid in dict.fromkeys(order) if sid in known]
    visible = {sid: sid not in set(hidden) for sid in known} if order else {}
    with Session(engine) as session:
        row = session.get(HomeSnapshot, layout_key(user_id)) or HomeSnapshot(key=layout_key(user_id))
        row.payload = {"order": order, "visible": visible}
        row.generated_at = utcnow()
        session.add(row)
        session.commit()
    return entries(user_id)
