"""Sbírky knih (jako playlisty)."""
from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine
import pytest
from fastapi import HTTPException

import app.routes.spoken as routes
from app.models import SpokenBook


def test_collection_crud_and_ownership():
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    me, other = ("me", "x"), ("other", "x")
    with Session(e) as s:
        s.add(SpokenBook(id="b1", source_ref="1", release_title="x", title="Krev elfů", requested_by_user_id="me", cover_url="c1"))
        s.add(SpokenBook(id="b2", source_ref="2", release_title="x", title="Meč osudu", requested_by_user_id="me"))
        s.commit()
        c = routes.create_collection(routes.CollectionIn(title="  Na dovolenou "), session=s, current=me)
        assert c["title"] == "Na dovolenou" and c["bookIds"] == []
        routes.add_to_collection(c["id"], routes.CollectionBookIn(bookId="b1"), session=s, current=me)
        out = routes.add_to_collection(c["id"], routes.CollectionBookIn(bookId="b2"), session=s, current=me)
        routes.add_to_collection(c["id"], routes.CollectionBookIn(bookId="b1"), session=s, current=me)  # podruhé nic
        assert out["bookIds"] == ["b1", "b2"] and out["coverUrl"] == "c1"
        assert routes.remove_from_collection(c["id"], "b1", session=s, current=me)["bookIds"] == ["b2"]
        with pytest.raises(HTTPException):
            routes.add_to_collection(c["id"], routes.CollectionBookIn(bookId="b1"), session=s, current=other)
        assert routes.list_collections(session=s, current=other)["collections"] == []
        routes.delete_collection(c["id"], session=s, current=me)
        assert routes.list_collections(session=s, current=me)["collections"] == []
        assert s.get(SpokenBook, "b1") is not None  # knihy zůstávají
