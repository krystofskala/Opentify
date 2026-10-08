"""Český rozhlas (mujrozhlas.cz) jako zdroj knih a rozhlasových her."""
import asyncio
from pathlib import Path

from sqlalchemy.pool import StaticPool
from sqlmodel import Session, SQLModel, create_engine

import app.routes.spoken as routes
from app.models import SpokenBook, SpokenFile
from app.spoken import rozhlas

_DESC = """Bářin život se nevyvíjel podle jejích představ.

Čte: Andrea Elsnerová a Kamil Halbich

Připravil: Anna Smrčková

Napsala: Alena Mornštajnová"""


def test_split_title():
    assert rozhlas.split_title("Zdeněk Jirotka: Saturnin. Slavný humoristický román v podání Ondřeje Havelky") == {
        "author": "Zdeněk Jirotka", "title": "Saturnin"}
    assert rozhlas.split_title("Karel Čapek, Josef Čapek: Živý plamen. Volání dálek")["author"] == "Karel Čapek, Josef Čapek"
    # Bez autora jen název bez reklamního dovětku.
    assert rozhlas.split_title("Bílá velryba. Slavný příběh o souboji člověka s přírodou") == {
        "author": None, "title": "Bílá velryba"}
    assert rozhlas.split_title("Karel Čapek: Apokryfy (1/2)")["title"] == "Apokryfy"


def test_credits_from_description():
    assert rozhlas.credits(_DESC) == {"narrator": "Andrea Elsnerová, Kamil Halbich", "author": "Alena Mornštajnová"}
    drama = "Hrají: Aleš Procházka, Martin Štěpánek, Jiří Schwarz, Pavel Rímský a další\nRežie: Vladimír Rusko"
    assert rozhlas.credits(drama)["narrator"] == "Aleš Procházka, Martin Štěpánek, Jiří Schwarz"


def test_plain_description():
    assert rozhlas.plain("<p>První&nbsp;odstavec</p><p>Čte: <b>X Y</b></p>") == "První\xa0odstavec\nČte: X Y"


def test_spoken_shows_only():
    for show in ("Četba na pokračování", "Hra na neděli", "Rozhlasová hra", "Čtenářský deník", "Povídky klasiků"):
        assert rozhlas._spoken_show(show), show
    # Publicistika ne, i když se jmenuje "seriál" nebo "příběhy".
    for show in ("Seriál Radiožurnálu", "Příběhy z kalendáře", "České knihy, které musíte znát", None):
        assert not rozhlas._spoken_show(show), show
    assert rozhlas._kind("Hra na neděli", "Láska je dobrej matroš") == "drama"
    assert rozhlas._kind("Četba na pokračování", "Čas vos") == "book"


def test_part_titles():
    eps = [{"part": 1, "title": "Karel Čapek: Věci kolem nás"}, {"part": 2, "title": "O zvláštních vínech"}]
    assert rozhlas.part_titles("Karel Čapek: Věci kolem nás", eps) == ["Část 1", "O zvláštních vínech"]
    same = [{"part": i, "title": "Anglické listy - První dojmy"} for i in (1, 2)]
    assert rozhlas.part_titles("Karel Čapek: Anglické listy", same) == ["Část 1", "Část 2"]


def _release():
    return {
        "source": "rozhlas", "ref": "cro:s:abc", "infohash": "", "title": "Alena Mornštajnová: Čas vos. Tichý příběh",
        "sizeBytes": 30, "seeders": 1, "files": 2, "uploader": "Četba na pokračování", "durationText": "55 min",
        "coverUrl": "https://example.invalid/c.jpg", "kind": "book", "totalParts": 14, "complete": False,
        "description": _DESC,
        "episodes": [
            {"id": "e1", "part": 1, "title": "Čas vos (1/14)", "url": "https://example.invalid/1.mp3", "size": 10, "duration": 1},
            {"id": "e2", "part": 2, "title": "Čas vos (2/14)", "url": "https://example.invalid/2.mp3", "size": 20, "duration": 1},
        ],
    }


def test_files_and_acquire(monkeypatch):
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)

    async def fake_release(ref):
        return _release() if ref == "cro:s:abc" else None

    monkeypatch.setattr(rozhlas, "release", fake_release)
    out = asyncio.run(routes.rozhlas_release_files("cro:s:abc"))
    assert [f["name"] for f in out["groups"][0]["files"]] == ["Část 1", "Část 2"] and out["groups"][0]["size"] == 30
    with Session(e) as s:
        body = routes.AcquireIn(source="rozhlas", ref="cro:s:abc", title="x")
        book = asyncio.run(routes.acquire_now(body, s, "me"))
        row = s.get(SpokenBook, book["id"])
        assert row.source == "rozhlas" and row.source_ref == "cro:s:abc"
        assert (row.title, row.author, row.narrator, row.kind) == (
            "Čas vos", "Alena Mornštajnová", "Andrea Elsnerová, Kamil Halbich", "book")
        assert len(row.source_files["episodes"]) == 2 and row.metadata_source == "rozhlas"
        assert asyncio.run(routes.acquire_now(body, s, "me"))["id"] == book["id"]


def test_finish_names_parts_and_keeps_manual_kind(monkeypatch, tmp_path: Path):
    import app.spoken.acquire as acquire

    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    monkeypatch.setattr(acquire, "engine", e)
    monkeypatch.setattr(rozhlas, "fetch_cover", lambda url, dest: dest.write_bytes(b"jpg") or True)
    rel = _release()
    with Session(e) as s:
        s.add(SpokenBook(id="b1", source="rozhlas", source_ref="cro:s:abc", release_title=rel["title"], title="Čas vos (1/14)",
                         kind="drama", requested_by_user_id="me"))
        s.add(SpokenFile(id="f1", book_id="b1", position=0, path=str(tmp_path / "001.mp3"), title="tag"))
        s.commit()
    acquire.rozhlas_finish("b1", tmp_path, rel)
    with Session(e) as s:
        book = s.get(SpokenBook, "b1")
        assert book.title == "Čas vos" and book.kind == "drama"  # ručně přepnuté zůstává
        assert book.cover_url == "spoken/books/b1/cover" and (tmp_path / "cover.jpg").is_file()
        assert s.get(SpokenFile, "f1").title == "Část 1"


def test_set_kind():
    e = create_engine("sqlite://", connect_args={"check_same_thread": False}, poolclass=StaticPool)
    SQLModel.metadata.create_all(e)
    published = []

    async def fake_publish(user, kind, data):
        published.append(data["kind"])

    import app.events

    app.events.publish_event, orig = fake_publish, app.events.publish_event
    try:
        with Session(e) as s:
            s.add(SpokenBook(id="b1", source_ref="h", release_title="Hobit", title="Hobit", requested_by_user_id="me"))
            s.commit()
            out = asyncio.run(routes.set_kind("b1", routes.KindIn(kind="drama"), session=s, current=("me", "x"), _local_only=None))
            assert out["kind"] == "drama" and published == ["drama"]
    finally:
        app.events.publish_event = orig


def test_show_id_survives_null_data():
    assert rozhlas._show_id({"relationships": {"show": {"data": None}}}) is None
    assert rozhlas._show_id({}) is None


def test_download_skips_failed_part_and_keeps_others(tmp_path: Path, monkeypatch):
    import httpx

    def handler(request):
        if request.url.path.endswith("/2.mp3"):
            return httpx.Response(404)
        return httpx.Response(200, content=b"x" * 10)

    real = httpx.Client

    def fake_client(*a, **kw):
        kw.pop("proxy", None)
        return real(transport=httpx.MockTransport(handler), **kw)

    monkeypatch.setattr(httpx, "Client", fake_client)
    eps = [{"url": "https://e/1.mp3", "size": 10}, {"url": "https://e/2.mp3", "size": 10}, {"url": "https://e/3.mp3"}]
    files = []
    failed = rozhlas.download(eps, tmp_path, lambda s: None, files.append)
    assert failed == [1] and [p.name for p in files] == ["001.mp3", "003.mp3"]
    # Po restartu se hotové díly nestahují znovu (i bez známé velikosti).
    again = []
    rozhlas.download(eps, tmp_path, lambda s: None, again.append)
    assert [p.name for p in again] == ["001.mp3", "003.mp3"]
