"""Blend -- společné mixy dvou profilů (jako Spotify Blend).

Vznikne jen se souhlasem obou: jeden pozve (`pending`), druhý přijme
(`active`). Kdokoli z dvojice může kdykoli odejít -- mixy zmizí oběma.
Každá dvojice má tři mixy, každý člen svou kopii (playlist s
`source="blend:<id>:<druh>"`, sekce Domů "blends"):

- **Blend** -- nejposlouchanější skladby obou, střídavě jedna a druhá.
- **Vaše best of** -- co posloucháte oba (průnik), doplněné o skladby
  společných interpretů.
- **Nové objevy** -- co jeden poslouchá a druhý ještě neslyšel, oběma směry.

Podklad: poslechy za posledních ~2 roky (i importovaná historie ze Spotify).
Přestavuje se denně (generátor Domů `personal:blends`) a hned po přijetí.
"""

from __future__ import annotations

from collections import Counter
from datetime import timedelta
from itertools import zip_longest

from sqlmodel import Session, select

from app.db import engine
from app.models import AppUser, Blend, Listen, Playlist, PlaylistItem, PlaylistKind, Recording
from app.utils import utcnow

_LIMIT = 50
_WINDOW = timedelta(days=730)
TTL = timedelta(days=1)

KINDS = {
    "blend": ("Blend", "Vaše nejposlouchanější, střídavě"),
    "best": ("Vaše best of", "Co posloucháte oba"),
    "new": ("Nové objevy", "Co poslouchá jeden a druhý ještě neslyšel"),
}


def source_for(blend_id: str, kind: str) -> str:
    return f"blend:{blend_id}:{kind}"


def _counts(session: Session, user_id: str) -> Counter[str]:
    since = utcnow() - _WINDOW
    rows = session.exec(
        select(Listen.recording_id).where(Listen.user_id == user_id, Listen.played_at >= since)  # type: ignore[operator]
    ).all()
    return Counter(rows)


def _interleave(*lists: list[str], limit: int = _LIMIT) -> list[str]:
    out: list[str] = []
    seen: set[str] = set()
    for group in zip_longest(*lists):
        for rid in group:
            if rid and rid not in seen:
                seen.add(rid)
                out.append(rid)
                if len(out) >= limit:
                    return out
    return out


def compute(session: Session, user_a: str, user_b: str) -> dict[str, list[str]]:
    a, b = _counts(session, user_a), _counts(session, user_b)
    top_a = [rid for rid, _ in a.most_common(_LIMIT * 2)]
    top_b = [rid for rid, _ in b.most_common(_LIMIT * 2)]

    shared = sorted(set(a) & set(b), key=lambda rid: -min(a[rid], b[rid]))
    best = shared[:_LIMIT]
    if len(best) < _LIMIT:
        # Doplnit skladbami interpretů, které poslouchají oba.
        artist_of = {
            r.id: r.artist_id
            for r in session.exec(select(Recording).where(Recording.id.in_(list(set(a) | set(b))))).all()  # type: ignore[union-attr]
        }
        artists_a = {artist_of.get(rid) for rid in a} - {None}
        artists_b = {artist_of.get(rid) for rid in b} - {None}
        common = artists_a & artists_b
        extra = sorted(
            (rid for rid in set(a) | set(b) if artist_of.get(rid) in common and rid not in best),
            key=lambda rid: -(a[rid] + b[rid]),
        )
        best += extra[: _LIMIT - len(best)]

    blend = _interleave(shared[:10], top_a, top_b)
    new = _interleave([rid for rid in top_a if rid not in b], [rid for rid in top_b if rid not in a])
    return {"blend": blend, "best": best, "new": new}


def build(blend_id: str) -> int:
    """(Pře)staví mixy dvojice -- obě kopie. Vrátí počet skladeb hlavního mixu."""
    from app.home import generators as g

    with Session(engine) as session:
        blend = session.get(Blend, blend_id)
        if blend is None or blend.status != "active":
            return 0
        users = {u.id: u for u in session.exec(select(AppUser).where(AppUser.id.in_([blend.user_a, blend.user_b]))).all()}  # type: ignore[union-attr]
        mixes = compute(session, blend.user_a, blend.user_b)
    for owner, partner in ((blend.user_a, blend.user_b), (blend.user_b, blend.user_a)):
        partner_name = users[partner].name if partner in users else "?"
        for kind, ids in mixes.items():
            title, description = KINDS[kind]
            if not ids:
                # Zatím nic společného -- prázdnou kartu neukazovat.
                with Session(engine) as session:
                    for p in session.exec(
                        select(Playlist).where(Playlist.owner_user_id == owner, Playlist.source == source_for(blend_id, kind))
                    ).all():
                        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == p.id)).all():
                            session.delete(item)
                        session.delete(p)
                    session.commit()
                continue
            g._save_playlist(
                owner=owner,
                source=source_for(blend_id, kind),
                title=f"{title} · ty & {partner_name}",
                description=description,
                kind=PlaylistKind.GENERATED_RECOMMENDATION,
                section="blends",
                recording_ids=ids,
                cover_urls=g._covers_for(ids[:40]),
                ttl=TTL,
            )
    with Session(engine) as session:
        blend = session.get(Blend, blend_id)
        if blend is not None:
            blend.built_at = utcnow()
            session.add(blend)
            session.commit()
    return len(mixes["blend"])


def drop_playlists(session: Session, blend_id: str) -> None:
    rows = session.exec(select(Playlist).where(Playlist.source.like(f"blend:{blend_id}:%"))).all()  # type: ignore[union-attr]
    for playlist in rows:
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all():
            session.delete(item)
        session.delete(playlist)


async def build_for_current_user() -> int:
    """Generátor Domů (`personal:blends`): denně přestaví blendy profilu."""
    import asyncio

    from app.home.generators import home_user

    user_id = home_user()
    with Session(engine) as session:
        ids = [
            b.id
            for b in session.exec(select(Blend).where(Blend.status == "active")).all()
            if user_id in (b.user_a, b.user_b) and user_id == b.user_a  # dvojici staví jednou (za prvního)
        ]
    total = 0
    for blend_id in ids:
        total += await asyncio.to_thread(build, blend_id)
    return total
