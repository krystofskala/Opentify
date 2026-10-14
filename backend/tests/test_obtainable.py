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


def test_pri_otevreni_mixu_vymeni_selhanou_jen_ve_vygenerovanem():
    """A6: stažení selhalo až po sestavení mixu -> výměna při otevření;
    vlastní playlist uživatele zůstává, jak ho udělal."""
    from sqlmodel import select

    from app.home.obtainable import refresh_failed_items
    from app.models import Playlist, PlaylistItem, PlaylistKind

    with Session(engine) as s:
        artist = Artist(name="Daves " + _RUN)
        s.add(artist)
        s.flush()
        live = Recording(title="Pretty Polly (Live)", artist_id=artist.id)
        studio = Recording(title="Pretty Polly", artist_id=artist.id)
        ok = Recording(title="Other " + _RUN, artist_id=artist.id)
        s.add_all([live, studio, ok])
        s.flush()
        s.add(MediaAsset(recording_id=live.id, status=MediaAssetStatus.FAILED))
        s.add(MediaAsset(recording_id=studio.id, status=MediaAssetStatus.AVAILABLE, storage_path="/x"))
        mix = Playlist(owner_user_id="u-" + _RUN, title="Denní mix 1", kind=PlaylistKind.GENERATED_RECOMMENDATION, source="personal:daily:1")
        own = Playlist(owner_user_id="u-" + _RUN, title="Moje", kind=PlaylistKind.USER, source="user")
        s.add_all([mix, own])
        s.flush()
        for p in (mix, own):
            for pos, rid in enumerate([ok.id, live.id]):
                s.add(PlaylistItem(playlist_id=p.id, recording_id=rid, position=pos))
        s.commit()

        def items(p):
            return [i.recording_id for i in s.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == p.id).order_by(PlaylistItem.position)).all()]

        assert refresh_failed_items(s, mix) is True
        assert items(mix) == [ok.id, studio.id]
        assert refresh_failed_items(s, mix) is False
        assert refresh_failed_items(s, own) is False
        assert items(own) == [ok.id, live.id]
