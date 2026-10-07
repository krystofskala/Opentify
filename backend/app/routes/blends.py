"""`/blends` -- společné mixy dvou profilů (viz app/blends.py)."""

from __future__ import annotations


from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel
from sqlmodel import Session, select

from app import blends
from app.auth import get_current_user
from app.db import engine
from app.models import AppUser, Blend, Playlist

blends_router = APIRouter(prefix="/blends", tags=["blends"])


def _out(session: Session, blend: Blend, me: str) -> dict:
    partner_id = blend.user_b if blend.user_a == me else blend.user_a
    partner = session.get(AppUser, partner_id)
    playlists = session.exec(
        select(Playlist).where(Playlist.owner_user_id == me, Playlist.source.like(f"blend:{blend.id}:%"))  # type: ignore[union-attr]
    ).all()
    order = list(blends.KINDS)
    playlists.sort(key=lambda p: order.index((p.source or "").rsplit(":", 1)[-1]) if (p.source or "").rsplit(":", 1)[-1] in order else 9)
    return {
        "id": blend.id,
        "partner": {"id": partner_id, "name": partner.name if partner else "?"},
        "status": blend.status,
        # Pozvánka čeká na MĚ (ne já na partnera).
        "incoming": blend.status == "pending" and blend.created_by != me,
        "playlists": [{"id": p.id, "title": p.title, "coverUrls": p.cover_urls or []} for p in playlists],
    }


@blends_router.get("")
def list_blends(current: tuple[str, str] = Depends(get_current_user)):
    me = current[0]
    with Session(engine) as session:
        mine = [b for b in session.exec(select(Blend)).all() if me in (b.user_a, b.user_b)]
        taken = {b.user_a for b in mine} | {b.user_b for b in mine}
        # Nabídnout jen profily, které souhlasí se sdílením poslechů ("Sdílet,
        # co poslouchám") -- kamarádi nemají vidět všechny profily na serveru.
        from app.home.extra_sections import shares_listening

        me_user = session.get(AppUser, me)
        is_admin = me_user is not None and me_user.role == "admin"
        profiles = [
            {"id": u.id, "name": u.name}
            for u in session.exec(select(AppUser).order_by(AppUser.name)).all()
            if u.id != me and u.id not in taken and (is_admin or shares_listening(session, u.id))
        ]
        return {"items": [_out(session, b, me) for b in mine], "profiles": profiles}


class NewBlendIn(BaseModel):
    partner_id: str


@blends_router.post("")
def invite(body: NewBlendIn, current: tuple[str, str] = Depends(get_current_user)):
    me = current[0]
    if body.partner_id == me:
        raise HTTPException(status_code=400, detail="Sám se sebou mix nejde.")
    with Session(engine) as session:
        if session.get(AppUser, body.partner_id) is None:
            raise HTTPException(status_code=404, detail="Profil neexistuje.")
        for b in session.exec(select(Blend)).all():
            if {b.user_a, b.user_b} == {me, body.partner_id}:
                raise HTTPException(status_code=409, detail="S tímhle profilem už společný mix máš (nebo čeká).")
        blend = Blend(user_a=me, user_b=body.partner_id, created_by=me, status="pending")
        session.add(blend)
        session.commit()
        session.refresh(blend)
        return _out(session, blend, me)


@blends_router.post("/{blend_id}/accept")
async def accept(blend_id: str, current: tuple[str, str] = Depends(get_current_user)):
    me = current[0]
    with Session(engine) as session:
        blend = session.get(Blend, blend_id)
        if blend is None or me not in (blend.user_a, blend.user_b) or blend.created_by == me:
            raise HTTPException(status_code=404, detail="Pozvánka neexistuje.")
        blend.status = "active"
        session.add(blend)
        session.commit()
    await blends.build_async(blend_id)
    from app.home.service import invalidate_home_cache

    await invalidate_home_cache()
    with Session(engine) as session:
        return _out(session, session.get(Blend, blend_id), me)


@blends_router.delete("/{blend_id}")
async def leave(blend_id: str, current: tuple[str, str] = Depends(get_current_user)):
    """Odmítnout pozvánku, zrušit vlastní, nebo z mixu odejít -- zmizí oběma."""
    me = current[0]
    with Session(engine) as session:
        blend = session.get(Blend, blend_id)
        if blend is None or me not in (blend.user_a, blend.user_b):
            raise HTTPException(status_code=404, detail="Společný mix neexistuje.")
        blends.drop_playlists(session, blend_id)
        session.delete(blend)
        session.commit()
    from app.home.service import invalidate_home_cache

    await invalidate_home_cache()
    return {"deleted": True}
