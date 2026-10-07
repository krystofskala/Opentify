"""Blend -- společné mixy dvou profilů (jako Spotify Blend).

Vznikne jen se souhlasem obou: jeden pozve (`pending`), druhý přijme
(`active`). Kdokoli z dvojice může kdykoli odejít -- mixy zmizí oběma.
Každý člen má svou kopii (playlist s `source="blend:<id>:<druh>"`, sekce
Domů "blends"); vidí ji jen on.

- **Blend** -- vaše nejoblíbenější, střídavě jedna a druhá. Komu poslechy
  zatím chybí, za toho stranu doplní hudba podobná té jeho -- jinak by to
  byl mix jen jednoho (živě: Matěj s 1 poslechem, 7. 10.).
- **Vaše best of** -- co posloucháte oba, doplněné o společné interprety.
- **Nové objevy** -- co poslouchá jeden a druhý ještě neslyšel, oběma
  směry; bez skladeb, které už jsou v Blendu (dřív skoro totéž).
- **Společné objevy** -- nová hudba podobná vkusu vás obou (nikdo z vás ji
  neslyšel).

Vkus z vrstev vkusu (app/home/activation.py: co teď "žije" + trvalý, poslech
z algoritmu v trvalém třetinou, bez "Nepočítat do vkusu" a vypnutých zdrojů)
a filtry OBOU: nic, co jeden z vás "nelíbí", "míň takových" nebo přeskočil.
Přestavuje se denně (generátor Domů `personal:blends`) a hned po přijetí.
"""

from __future__ import annotations

import asyncio
import random
from datetime import timedelta
from itertools import zip_longest

from sqlmodel import Session, select

from app.db import engine
from app.models import AppUser, Blend, Playlist, PlaylistItem, PlaylistKind, Recording
from app.utils import utcnow

_LIMIT = 50
THIN = 15  # méně oblíbených skladeb -> strana Blendu se doplní podobnými
MIN_NEW = 15  # "Nové objevy" / "Společné objevy" s méně skladbami nevzniknou
TTL = timedelta(days=1)

KINDS = {
    "blend": ("Blend", "Vaše nejoblíbenější, střídavě"),
    "best": ("Vaše best of", "Co posloucháte oba"),
    "new": ("Nové objevy", "Co poslouchá jeden a druhý ještě neslyšel"),
    "discover": ("Společné objevy", "Nová hudba podobná vkusu vás obou"),
}


def source_for(blend_id: str, kind: str) -> str:
    return f"blend:{blend_id}:{kind}"


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


def _taste(user_id: str) -> tuple[dict[str, float], set[str]]:
    """(skladba -> skóre vkusu, slyšené) z vrstev vkusu profilu."""
    from app.home import activation as av

    act = av.cached(user_id)
    score = {r: act.medium.get(r, 0.0) + 0.5 * act.long.get(r, 0.0) for r in act.total}
    return score, set(act.total)


def _blocked(session: Session, user_ids: list[str]) -> tuple[set[str], set[str]]:
    """(skladby, interpreti), které nechce aspoň jeden z dvojice."""
    from app.home import repetition
    from app.home.feedback import deltas, fit_multiplier
    from app.library.dislikes import disliked_artist_ids, disliked_ids
    from app.models import SkipStreak

    tracks: set[str] = set()
    artists: set[str] = set()
    for uid in user_ids:
        tracks |= disliked_ids(session, uid) | repetition.imported_skips(uid)
        tracks |= set(
            session.exec(
                select(SkipStreak.recording_id).where(
                    SkipStreak.user_id == uid,
                    SkipStreak.streak >= 2,
                    SkipStreak.updated_at >= (utcnow() - timedelta(days=90)).replace(tzinfo=None),
                )
            ).all()
        )
        artists |= disliked_artist_ids(session, uid)
        artists |= {a for a, d in deltas(uid).items() if fit_multiplier(d) < 1}
    return tracks, artists


def compute(session: Session, user_a: str, user_b: str) -> dict[str, list[str]]:
    """Blend, best of a nové objevy (bez síťových dotazů). Doplnění tenké
    strany a společné objevy přidává `build_async`."""
    a, heard_a = _taste(user_a)
    b, heard_b = _taste(user_b)
    bad_tracks, bad_artists = _blocked(session, [user_a, user_b])
    ids = list(set(a) | set(b))
    artist_of: dict[str, str | None] = {}
    for k in range(0, len(ids), 500):
        for rid, aid in session.exec(
            select(Recording.id, Recording.artist_id).where(Recording.id.in_(ids[k : k + 500]))  # type: ignore[attr-defined]
        ).all():
            artist_of[rid] = aid

    def ok(rid: str) -> bool:
        return rid not in bad_tracks and artist_of.get(rid) not in bad_artists

    top_a = [r for r in sorted(a, key=lambda r: -a[r]) if ok(r)][: _LIMIT * 2]
    top_b = [r for r in sorted(b, key=lambda r: -b[r]) if ok(r)][: _LIMIT * 2]
    shared = sorted((r for r in heard_a & heard_b if ok(r)), key=lambda r: -min(a.get(r, 0), b.get(r, 0)))
    best = shared[:_LIMIT]
    if len(best) < _LIMIT:
        artists_a = {artist_of.get(r) for r in top_a} - {None}
        artists_b = {artist_of.get(r) for r in top_b} - {None}
        common = artists_a & artists_b
        extra = sorted(
            (r for r in set(top_a) | set(top_b) if artist_of.get(r) in common and r not in best),
            key=lambda r: -(a.get(r, 0) + b.get(r, 0)),
        )
        best += extra[: _LIMIT - len(best)]
    blend = _interleave(shared[:10], top_a, top_b)
    in_blend = set(blend)
    new = _interleave(
        [r for r in top_a if r not in heard_b and r not in in_blend],
        [r for r in top_b if r not in heard_a and r not in in_blend],
    )
    return {
        "blend": blend,
        "best": best,
        "new": new if len(new) >= MIN_NEW else [],
        "_top_a": top_a,
        "_top_b": top_b,
        "_shared": shared[:10],
    }


async def _similar_for(seeds: list[str], users: list[str], exclude: set[str], rng: random.Random, want: int) -> list[str]:
    """Skladby podobné semínkům, které nikdo z `users` neslyšel a které
    prošly jejich filtry (app/home/novelty.py)."""
    from app.home import lastfm_taste as lt
    from app.home import novelty

    if not seeds or want <= 0:
        return []
    try:
        cands = await asyncio.wait_for(lt.similar_track_ids(seeds[:8], exclude, rng, want * 2), timeout=40)
    except Exception:  # noqa: BLE001 -- doplněk; Blend vznikne i bez něj
        return []
    for uid in users:
        cands = await asyncio.to_thread(novelty.filter_new, uid, cands)
    return cands[:want]


def _save(blend_id: str, mixes: dict[str, list[str]]) -> int:
    from app.home import generators as g

    with Session(engine) as session:
        blend = session.get(Blend, blend_id)
        if blend is None or blend.status != "active":
            return 0
        users = {
            u.id: u
            for u in session.exec(select(AppUser).where(AppUser.id.in_([blend.user_a, blend.user_b]))).all()  # type: ignore[union-attr]
        }
    for owner, partner in ((blend.user_a, blend.user_b), (blend.user_b, blend.user_a)):
        partner_name = users[partner].name if partner in users else "?"
        for kind, (title, description) in KINDS.items():
            ids = mixes.get(kind) or []
            if not ids:
                # Zatím nic -- prázdnou kartu neukazovat.
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
    return len(mixes.get("blend") or [])


def _compute(user_a: str, user_b: str) -> dict[str, list[str]]:
    with Session(engine) as session:
        return compute(session, user_a, user_b)


async def build_async(blend_id: str) -> int:
    """(Pře)staví mixy dvojice -- obě kopie. Vrátí počet skladeb Blendu."""
    with Session(engine) as session:
        blend = session.get(Blend, blend_id)
        if blend is None or blend.status != "active":
            return 0
        user_a, user_b = blend.user_a, blend.user_b
    mixes = await asyncio.to_thread(_compute, user_a, user_b)
    rng = random.Random(f"blend:{blend_id}:{utcnow().date().isoformat()}")
    top_a, top_b, shared = mixes.pop("_top_a"), mixes.pop("_top_b"), mixes.pop("_shared")
    users = [user_a, user_b]
    known = set(top_a) | set(top_b)
    # Tenká strana (málo poslechů): doplnit hudbou podobnou jejím skladbám.
    if top_a and len(top_a) < THIN:
        top_a = top_a + await _similar_for(top_a, users, known, rng, THIN * 2 - len(top_a))
    if top_b and len(top_b) < THIN:
        top_b = top_b + await _similar_for(top_b, users, known, rng, THIN * 2 - len(top_b))
    mixes["blend"] = _interleave(shared, top_a, top_b)
    # Společné objevy: semínka z obou stran napůl.
    seeds = _interleave(top_a[:6], top_b[:6], limit=12)
    discover = await _similar_for(seeds, users, known | set(mixes["blend"]), rng, 30)
    mixes["discover"] = discover if len(discover) >= MIN_NEW else []
    return await asyncio.to_thread(_save, blend_id, mixes)


def build(blend_id: str) -> int:
    """Synchronní obal (nástroje); v API se volá `build_async`."""
    return asyncio.run(build_async(blend_id))


def drop_playlists(session: Session, blend_id: str) -> None:
    rows = session.exec(select(Playlist).where(Playlist.source.like(f"blend:{blend_id}:%"))).all()  # type: ignore[union-attr]
    for playlist in rows:
        for item in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == playlist.id)).all():
            session.delete(item)
        session.delete(playlist)


async def build_for_current_user() -> int:
    """Generátor Domů (`personal:blends`): denně přestaví blendy profilu."""
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
        total += await build_async(blend_id)
    return total
