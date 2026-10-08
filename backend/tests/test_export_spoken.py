"""Export dat: mluvené slovo (JSON) a podcasty (OPML)."""
import io
import json
import zipfile

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

from app.library.export import build_export
from app.models import PodcastShow, PodcastSubscription, SpokenBook, SpokenFavorite, SpokenProgress


def test_export_has_spoken_word_and_opml():
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    with Session(e) as s:
        s.add(SpokenBook(id="b1", source_ref="1", release_title="x", title="Krev elfů", author="Andrzej Sapkowski",
                         requested_by_user_id="other", series_name="Sága o zaklínači", series_number=3))
        s.add(SpokenBook(id="b2", source_ref="2", release_title="x", title="Cizí kniha", requested_by_user_id="other"))
        s.add(SpokenProgress(user_id="me", book_id="b1", file_id="f", position_ms=60000))
        s.add(SpokenFavorite(user_id="me", kind="person", ref="author:karel capek", name="Karel Čapek"))
        s.add(PodcastShow(id="p", feed_url="https://x/feed.xml?a=1&b=2", title="Vinohradská 12 & spol."))
        s.add(PodcastSubscription(user_id="me", show_id="p"))
        s.commit()
        data = build_export(s, "me", "Já")
    z = zipfile.ZipFile(io.BytesIO(data))
    spoken = json.loads(z.read("mluvene_slovo.json"))
    assert [b["title"] for b in spoken["books"]] == ["Krev elfů"]  # cizí kniha ne
    assert spoken["books"][0]["progress"]["positionMs"] == 60000 and spoken["books"][0]["seriesNumber"] == 3
    assert spoken["favoritePeople"] == [{"name": "Karel Čapek", "role": "author"}]
    opml = z.read("podcasty.opml").decode()
    assert 'xmlUrl="https://x/feed.xml?a=1&amp;b=2"' in opml and "Vinohradská 12 &amp; spol." in opml
