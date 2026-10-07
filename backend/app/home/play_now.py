"""Pusť teď a nekonečné hraní: další várka skladeb na jedno ťuknutí.

- **Pusť teď** (bez semínek): co profil obvykle pouští v tuhle denní dobu,
  vážené tím, jak moc skladby teď "žijí" (app/home/activation.py).
- **Nekonečné hraní** (semínka = co právě hrálo): navazuje na interprety
  semínek a na ty, které profil pouští ve stejných chvílích (podobnost z
  vlastní historie, ne z cizích dat).

Obojí ~80 % známé, ~20 % nové (Last.fm "posluchači pouštějí spolu").
Session řídí: interpret přeskočený v posledních 40 minutách jde stranou,
dvě přeskočení za sebou = změna směru (jiní interpreti než ti přeskočení).
Důvod se ukazuje jen pro celý výběr, ne u každé skladby.
"""

from __future__ import annotations

import asyncio
import random
import time
from collections import Counter
from datetime import timedelta
from typing import Any

from sqlmodel import Session, select

from app.db import engine
from app.home import activation as av
from app.models import Listen, PlayEvent, Recording, SkipStreak
from app.utils import utcnow

NEW_SHARE = 0.2
_CACHE_SECONDS = 600

# Čipy nálad (plán P2): nálada -> (kategorie z app/tags.SUBGENRES, štítky
# navíc, popisek). Nálada interpreta ze štítků Last.fm (cache týden) -- dokud
# nemáme rozbor zvuku (P4). "prekvap" = víc nového, bez denní doby.
MOODS: dict[str, tuple[str | None, tuple[str, ...], str]] = {
    "klid": ("chill", ("chill", "mellow", "relaxing", "calm", "acoustic", "ambient", "soft rock"), "Klid"),
    "energie": ("workout", ("energetic", "upbeat", "punk", "pop punk", "metal", "hard rock", "garage rock"), "Energie"),
    "soustredeni": ("focus", ("instrumental", "ambient", "post-rock", "classical", "piano", "jazz"), "Soustředění"),
    "melancholie": ("sad", ("sad", "melancholic", "melancholy", "mellow", "singer-songwriter", "slowcore"), "Melancholie"),
    "party": ("party", ("dance", "party", "upbeat", "funk", "disco", "pop"), "Párty"),
    "prekvap": (None, (), "Překvap mě"),
}


async def mood_fit(act: av.Activation, mood: str, limit: int = 80) -> dict[str, float]:
    """Interpret -> jak sedí na náladu (0..1) podle jeho štítků Last.fm."""
    from app.home import lastfm_taste as lt
    from app.models import Artist
    from app.tags import SUBGENRES

    category, extra, _label = MOODS[mood]
    terms = set(SUBGENRES.get(category or "", ())) | set(extra)
    top = [a for a, _ in act.blend(av.ARTIST_BLEND).most_common(limit)]
    with Session(engine) as session:
        names = {a: (session.get(Artist, a).name if session.get(Artist, a) else "") for a in top}
    sem = asyncio.Semaphore(8)

    async def one(artist_id: str) -> tuple[str, float]:
        async with sem:
            try:
                tags = [t.lower() for t in (await asyncio.wait_for(lt.artist_tags(names[artist_id]), 8))[:10]]
            except Exception:  # noqa: BLE001
                return artist_id, 0.0
        # Silnější štítky (dřív v seznamu) víc.
        score = sum(1.0 / (1 + i * 0.3) for i, t in enumerate(tags) if t in terms)
        return artist_id, min(1.0, score / 1.5)

    return dict(await asyncio.gather(*(one(a) for a in top if names.get(a))))
_cache: dict[str, tuple[float, av.Activation]] = {}


def _activation(user_id: str) -> av.Activation:
    hit = _cache.get(user_id)
    if hit and time.time() - hit[0] < _CACHE_SECONDS:
        return hit[1]
    act = av.compute(user_id)
    _cache[user_id] = (time.time(), act)
    return act


def _title_key(title: str) -> str:
    from app.download_match import core_title, tokens

    return " ".join(tokens(core_title(title or "")))


def _session_signals(session: Session, user_id: str) -> tuple[Counter, Counter, bool]:
    """(přeskočení interpreti, dohraní interpreti, změnit směr) za 40 minut."""
    since = (utcnow() - timedelta(minutes=40)).replace(tzinfo=None)
    rows = session.exec(
        select(PlayEvent.recording_id, PlayEvent.end_reason)
        .where(PlayEvent.user_id == user_id, PlayEvent.ended_at >= since)
        .order_by(PlayEvent.ended_at)
    ).all()
    skipped, done = Counter(), Counter()
    for rid, reason in rows:
        rec = session.get(Recording, rid)
        if rec is None or not rec.artist_id:
            continue
        if reason == "skipped":
            skipped[rec.artist_id] += 1
        elif reason == "completed":
            done[rec.artist_id] += 1
    last_two = [r for _rid, r in rows[-2:]]
    return skipped, done, len(last_two) == 2 and all(r == "skipped" for r in last_two)


def pick(
    user_id: str, seeds: list[str], played: list[str], size: int, rng: random.Random,
    mood: str | None = None, moods: dict[str, float] | None = None, new_share: float = NEW_SHARE,
) -> tuple[list[str], list[str], str]:
    """Známé skladby + semínka pro nové. Vrací (známé, semínka_pro_nové, důvod)."""
    from app.home.quick_picks import time_profile
    from app.library.dislikes import disliked_artist_ids

    act = _activation(user_id)
    with Session(engine) as session:
        banned = disliked_artist_ids(session, user_id)
        skipped_artists, done_artists, turn = _session_signals(session, user_id)
        _ctx, time_artists, _recs = time_profile(session, user_id)
        recent_order = list(
            session.exec(
                select(Listen.recording_id)
                .where(Listen.user_id == user_id, Listen.played_at >= (utcnow() - timedelta(hours=3)).replace(tzinfo=None))
                .order_by(Listen.played_at.desc())  # type: ignore[attr-defined]
            ).all()
        )
        recent = set(recent_order)
        # Nový profil: všechno, co slyšel, je z posledních 3 h (a ta se
        # vynechávají) -- nové pak naváže aspoň na to a na lajky. Dřív
        # zůstalo Pusť teď prázdné i po prvních poslechech (UX audit 7. 10.).
        fallback_seeds = list(dict.fromkeys(recent_order))[:3]
        if not fallback_seeds:
            from app.library.spotify_import import LIKED_SONGS_SOURCE
            from app.models import Playlist, PlaylistItem

            liked = session.exec(
                select(Playlist.id).where(Playlist.owner_user_id == user_id, Playlist.source == LIKED_SONGS_SOURCE)
            ).first()
            if liked:
                fallback_seeds = list(
                    session.exec(
                        select(PlaylistItem.recording_id)
                        .where(PlaylistItem.playlist_id == liked)
                        .order_by(PlaylistItem.position.desc())  # type: ignore[attr-defined]
                        .limit(3)
                    ).all()
                )
        ninety = (utcnow() - timedelta(days=90)).replace(tzinfo=None)
        skipped_tracks = set(
            session.exec(
                select(SkipStreak.recording_id).where(
                    SkipStreak.user_id == user_id, SkipStreak.streak >= 2, SkipStreak.updated_at >= ninety
                )
            ).all()
        )
        seed_artists = {r.artist_id for r in (session.get(Recording, s) for s in seeds) if r and r.artist_id}
        seed_title = None
        if seeds:
            first = session.get(Recording, seeds[-1])
            seed_title = first.title if first else None

    if seed_artists:
        near = act.co_listened_artists(seed_artists)
        top = max(near.values(), default=1)
        fit = {a: 0.3 + 0.7 * n / top for a, n in near.items()}
        for a in seed_artists:
            fit[a] = 1.0
        reason = f"Navazuje na {seed_title}" if seed_title else "Navazuje na to, co hrálo"
    else:
        top = max(time_artists.values(), default=0) or 1.0
        fit = {a: 0.15 + w / top for a, w in time_artists.items()}
        reason = "Podle toho, co posloucháš v tuhle dobu"
    if mood == "prekvap":
        fit, time_artists = {}, Counter()  # bez denní doby -- celý vkus
        reason = "Překvap mě – víc nového"
    elif mood and moods is not None:
        label = MOODS[mood][2]
        fit = {a: fit.get(a, 0.3) * (0.08 + m) for a, m in moods.items()}
        reason = f"{label} – z toho, co posloucháš"
    if turn:
        # Dvakrát po sobě přeskočeno: jiným směrem -- interpreti přeskočených
        # ven a víc prostoru těm, které se dohrály.
        reason = "Zkouším jiný směr"
    from app.home.feedback import deltas as feedback_deltas
    from app.home.feedback import fit_multiplier

    manual = feedback_deltas(user_id)
    exclude = set(played) | recent | skipped_tracks | set(seeds)
    max_long = max(act.long.values(), default=0) or 1.0
    max_med = max(act.medium.values(), default=0) or 1.0
    # Tatáž píseň v jiné verzi ("Salt Creek" od Blake & Rice a pak od Rice
    # sólo) se v jedné session nevrací.
    played_titles = {_title_key(act.title_of.get(r, "")) for r in exclude} - {""}

    def score(rid: str) -> float:
        artist = act.artist_of.get(rid)
        if not artist or artist in banned or rid in exclude:
            return 0.0
        if _title_key(act.title_of.get(rid, "")) in played_titles:
            return 0.0
        base = act.medium.get(rid, 0.0) / max_med + 0.5 * act.long.get(rid, 0.0) / max_long
        f = fit.get(artist, 0.01 if moods is not None and mood != "prekvap" else
                    (0.05 if (seed_artists or time_artists) else 1.0))
        if skipped_artists.get(artist):
            f *= 0.1 if turn else 0.4
        if done_artists.get(artist):
            f *= 1.3
        if artist in manual:
            f *= fit_multiplier(manual[artist])  # "víc / míň takových"
        return base * f

    from app.home.personal_mixes import _cap_per_artist, _spread, _weighted_order

    ordered = _weighted_order(list(act.total), score, rng)
    seen_titles: set[str] = set()
    unique: list[str] = []
    for r in ordered:
        key = _title_key(act.title_of.get(r, ""))
        if score(r) > 0 and (not key or key not in seen_titles):
            seen_titles.add(key)
            unique.append(r)
    ordered = unique
    known_target = max(1, round(size * (1 - new_share)))
    from app.home import energy_flow

    familiar = _spread(_cap_per_artist(ordered, act.artist_of, 1)[:known_target], act.artist_of)
    familiar = energy_flow.order(familiar, act.artist_of)  # plynulé navazování (P3)
    # Semínka pro nové: semínka nekonečného hraní, jinak první známé.
    new_seeds = (seeds[-2:] if seeds else []) + familiar[:2]
    if not new_seeds and fallback_seeds:
        new_seeds = fallback_seeds
        with Session(engine) as session:
            first = session.get(Recording, fallback_seeds[0])
        reason = f"Navazuje na {first.title}" if first else reason
    return familiar, new_seeds, reason


async def next_chunk(
    user_id: str, seeds: list[str], played: list[str], size: int = 8, mood: str | None = None
) -> dict[str, Any]:
    from app.home import lastfm_taste as lt
    from app.home.personal_mixes import _drop_heard

    rng = random.Random(f"{user_id}:{int(time.time() // 60)}:{len(played)}")
    mood = mood if mood in MOODS else None
    moods = None
    if mood and mood != "prekvap":
        moods = await mood_fit(await asyncio.to_thread(_activation, user_id), mood)
    new_share = 0.5 if mood == "prekvap" else NEW_SHARE
    familiar, new_seeds, reason = await asyncio.to_thread(
        pick, user_id, seeds, played, size, rng, mood, moods, new_share
    )
    want_new = size - len(familiar)
    new: list[str] = []
    if want_new > 0 and new_seeds:
        act = _activation(user_id)
        exclude = set(act.total) | set(played) | set(familiar) | set(seeds)
        try:
            cands = await asyncio.wait_for(lt.similar_track_ids(new_seeds, exclude, rng, want_new * 2), timeout=12)
        except Exception:  # noqa: BLE001 -- bez nových je to pořád dobrá várka
            cands = []

        class _T:  # _drop_heard čte jen .activation
            activation = act

        new = await asyncio.to_thread(_drop_heard, _T, cands)
        # Nový interpret ne zároveň mezi známými ani dvakrát mezi novými.
        from app.home.personal_mixes import _artists_of

        artist_of = await asyncio.to_thread(_artists_of, new)
        used = {act.artist_of.get(r) for r in familiar}
        kept = []
        for rid in new:
            a = artist_of.get(rid)
            if a and a in used:
                continue
            used.add(a)
            kept.append(rid)
        new = kept[:want_new]
    # Nové proložit mezi známé (ne všechny na konec).
    out: list[str] = []
    step = max(1, len(familiar) // max(1, len(new))) if new else len(familiar) or 1
    fi = iter(familiar)
    for i in range(len(familiar) + len(new)):
        if new and (i + 1) % (step + 1) == 0:
            out.append(new.pop(0))
        else:
            nxt = next(fi, None)
            if nxt is None:
                out.extend(new)
                break
            out.append(nxt)
    if not out:
        # Nový profil bez historie: nic nevnucovat (žádné žebříčky), jen říct proč.
        reason = "Zatím nevím, co posloucháš – pusť si něco z Hledat a příště navážu."
    return {"recordingIds": out[:size], "reason": reason}
