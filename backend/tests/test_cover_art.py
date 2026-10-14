from app.home.cover_art import daily_label


def test_daily_label_same_shape_for_every_mix_kind():
    assert daily_label("Psychedelic rock · Tame Impala, Pond a další · naposledy 2019") == {
        "style": "psychedelický rock",
        "artistsLine": "Tame Impala, Pond a další",
    }
    assert daily_label("Stálice · Bob Dylan, Beck a další") == {"style": "Stálice", "artistsLine": "Bob Dylan, Beck a další"}
    # Běžná skupina má styl až za interprety -- dřív byl štítkem seznam jmen.
    assert daily_label("Fruit Bats, Ben Howard a další · folk") == {
        "style": "folk",
        "artistsLine": "Fruit Bats, Ben Howard a další",
    }
    # Bez stylu: zaměřením je první interpret, ne prázdný štítek.
    assert daily_label("twenty one pilots, Muse a další") == {
        "style": "twenty one pilots",
        "artistsLine": "twenty one pilots, Muse a další",
    }
    assert daily_label("") == {"style": None, "artistsLine": None}


def test_daily_label_genre_in_czech():
    assert daily_label("Czech · Zuby Nehty, Vltava a další · naposledy 2026")["style"] == "česká scéna"
    assert daily_label("Psychedelic rock · Tame Impala, Local H a další")["style"] == "psychedelický rock"
    # neznámý štítek zůstává
    assert daily_label("Reggae · Handmade Moments a další")["style"] == "Reggae"


def test_genre_name_by_language():
    from app.genre_names import genre_name

    assert genre_name("Alternative Rock") == "alternativní rock"
    assert genre_name("alternative rock", "en") == "alternative rock"
    assert genre_name("bluegrass") == "bluegrass"
