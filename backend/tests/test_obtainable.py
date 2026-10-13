"""Nesehnatelné skladby (stažení selhalo) ve výběrech nahradit jinou verzí
téže skladby, jinak vynechat (13. 10.)."""
import uuid

from sqlmodel import Session

from app.db import engine
from app.home.obtainable import swap_failed
from app.models import Artist, MediaAsset, MediaAssetStatus, Recording

_RUN = uuid.uuid4().hex[:8]


def test_selhana_nahradi_jina_verze_nebo_vypadne():
    with Session(engine) as s:
        artist = Artist(name="Witmer " + _RUN)
        s.add(artist)
        s.flush()
        live = Recording(title="Are You A Dreamer?", artist_id=artist.id)
        studio = Recording(title="Are You a Dreamer", artist_id=artist.id)
        lost = Recording(title="Nowhere " + _RUN, artist_id=artist.id)
        ok = Recording(title="Fine " + _RUN, artist_id=artist.id)
        s.add_all([live, studio, lost, ok])
        s.flush()
        s.add(MediaAsset(recording_id=live.id, status=MediaAssetStatus.FAILED))
        s.add(MediaAsset(recording_id=lost.id, status=MediaAssetStatus.FAILED))
        s.add(MediaAsset(recording_id=studio.id, status=MediaAssetStatus.AVAILABLE, storage_path="/x"))
        s.commit()
        ids = [ok.id, live.id, lost.id]
        expected = [ok.id, studio.id]
    assert swap_failed(ids) == expected
