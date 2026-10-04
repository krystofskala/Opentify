"""Dvojčata alb: různé remixy / edice v závorce nejsou totéž vydání."""
from app.models import Release
from app.tools.merge_release_twins import same_edition


def _r(title):
    return Release(artist_id="a", title=title)


def test_different_remixes_and_edits_are_not_twins():
    assert not same_edition(_r("Summertime Sadness (Monsieur Adi remix)"),
                            _r("Summertime Sadness (Lana Del Rey Vs. Cedric Gervais) (Cedric Gervais Remix)"))
    assert not same_edition(_r("Video Games (Joris Voorn edit)"), _r("Video Games"))
    assert not same_edition(_r("Every Kingdom"), _r("Every Kingdom (Deluxe Version)"))


def test_soundtrack_and_feat_suffixes_still_match():
    assert same_edition(_r("Blue Skies"), _r('Blue Skies (From "The New Look" Soundtrack)'))
    assert same_edition(_r("DAYWALKER!"), _r("DAYWALKER! (feat. CORPSE)"))
    assert same_edition(_r("Once Upon a Dream (Young Ruffian remix)"),
                        _r('Once Upon a Dream (From "Maleficent"/Young Ruffian Remix)'))
