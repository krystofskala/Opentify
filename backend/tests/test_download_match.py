"""Skutečné chybné výběry z auditu stahování (2026-10-03) a správné soubory,
které musí dál projít. Každý řádek odpovídá živému případu."""

import pytest

from app.download_match import artist_in, duration_ok, match_label, tokens

WRONG = [
    # (název, interpret, album, kandidát, kontext/složka)
    ("Harvest Moon", "Neil Young", "Harvest Moon", "Neil Young - Harvest Moon - 08 - Old King.flac", ""),
    ("Harvest Moon", "Neil Young", None, "Neil Young - Old King (Harvest Moon)", ""),
    ("Believe", "Cher", "Believe", "0104 - Reason to Believe.flac", "Backstage"),
    ("L'Amour Toujours", "Gigi D'Agostino", "L'Amour Toujours", "L'Amour Toujours II - 13 - Total Care (Elettro Gigi Dag).flac", ""),
    ("u + me = <3", "Olivia Rodrigo", None, "01 - Don't Leave Me.flac", "Don't Leave Me (2024)"),
    ("Cream of Gold", "Pavement", None, "2-12 Cream of Gold Intro (Jessamine).flac", "Farewell Horizontal"),
    (
        "It's Only Rock'n'Roll (But I Like It) (Remastered 2009)", "The Rolling Stones", "It's Only Rock 'n' Roll",
        "It's Only Rock 'n Roll - 09 Short and Curlies.flac", "",
    ),
    ("Cherry", "Lana Del Rey", "Lust For Life", "Cherry Blossom.flac", ""),
    ("Love", "Lana Del Rey", "Lust For Life", "Love Song.flac", ""),
    ("Let's Dance (2018 Remaster)", "David Bowie", "Let's Dance", "Without You.flac", "Loving the Alien"),
    ("Radio", "Future", None, "SPARKLEWOLF RADIO - 21 in the near future!.flac", ""),
    ("Something in the Way", "Nirvana", "Nevermind", "Nevermind - 12 - Something in the Way + Endless, Nameless.flac", ""),
    ("Changes", "Hayd", "Changes", "Hayd_Changes_02_Head In The Clouds.flac", ""),
    ("Giant", "Calvin Harris", None, "06 - Giant (Laidback Luke remix).flac", "Giant (remixes) (2019)"),
    ("Your Love", "The Outfield", None, "01 - Your Love (Diplo Remix).flac", "Your Love (Diplo Remix)"),
    ("Brighton Rock", "Queen", "Sheer Heart Attack", "01-09 Brighton Rock (Live At The Hammersmith Odeon).flac", "A Night At The Odeon"),
    ("Rosalie", "Thin Lizzy", "Fighting", "12 - Rosalie (Cowgirl's Song) (Live At The Hammersmith 7\" Edit).flac", ""),
    ("Pennyroyal Tea", "Nirvana", "In Utero", "Pennyroyal Tea (rehearsal).flac", ""),
    ("No Surprises", "Radiohead", "OK Computer", "No Surprises (BBC Radio 1 Evening session).flac", ""),
    ("22", "Taylor Swift", "Red", "Taylor Swift - 22 (Taylor's Version)", ""),
    ("Trees (Ned's Version)", "twenty one pilots", None, "Trees (Ned's Version) | filters / instrumentals / stems", ""),
    ("Norman fucking Rockwell", "Lana Del Rey", None, "Lana Del Rey - Norman Fucking Rockwell (Full Album)", ""),
    ("Muddy Water", "The Deslondes", None, "The Deslondes - Muddy Water (Live AF Version)", ""),
    ("Shapeshifter", "Duff Thompson", None, "Duff Thompson - Shapeshifter | Audiotree Live", ""),
    ("Day and Age", "Julian Lage", None, "Julian Lage - Day and Age (Live in Dublin)", ""),
    ("雨の中で", "Joe Hisaishi", None, "Joe Hisaishi - The Rain", ""),
    ("해금", "Agust D", None, "BTS - Dynamite", ""),
    ("That Means A Lot 那意味着很多", "The Beatles", None, "The Beatles - That Means A Lot", ""),
    ("There Will Be A Time", "Joe Kaplow", None, "Joe Kaplow - There Will Be A Time (Alternate Take)", ""),
    ("Possibilities", "Lana Del Rey", None, "Lana Del Rey - Say Yes To Heaven", ""),
    ("Cherry", "Lana Del Rey", None, "Cherry Blossom.flac", "Cherry Blossom"),
    ("Cherry", "Lana Del Rey", None, "01-lana_del_rey-cherry_blossom.flac", ""),
    ("All I Ever Wanted", "Vance Joy", None, "Vance Joy - &quot;All I Ever Wanted&quot; Live From Flinders St. Ballroom.mp3", ""),
    ("Georgia", "Vance Joy", None, "Vance Joy - Georgia  Mahogany Session.mp3", ""),
    ("Harvest Moon", "Neil Young", None, "Harvest Moon - 08 - Old King.flac", "Harvest Moon"),
    ("Harvest Moon", "Neil Young", None, "04 Harvest Moon.flac", "Neil Young - Unplugged (1993)"),
]

RIGHT = [
    ("Harvest Moon", "Neil Young", "Harvest Moon", "04 Harvest Moon.flac", "Harvest Moon"),
    ("Harvest Moon", "Neil Young", None, "Neil Young - Harvest Moon (Official Music Video)", ""),
    ("Harvest Moon", "Neil Young", None, "Harvest Moon", ""),
    (
        "It's Only Rock'n'Roll (But I Like It) (Remastered 2009)", "The Rolling Stones", "It's Only Rock 'n' Roll",
        "01 - It's Only Rock 'N Roll (But I Like It) [2009 Remaster].flac", "It's Only Rock 'n Roll",
    ),
    ("1952 Vincent Black Lightning", "Richard Thompson", "Rumor and Sigh", "05 - 1952 Vincent Black Lightning.flac", ""),
    ("22", "Taylor Swift", "Red", "Taylor Swift - 22", ""),
    ("Believe", "Cher", "Believe", "01 - Believe.flac", "Cher - Believe (1998) [FLAC]"),
    ("Let's Dance (2018 Remaster)", "David Bowie", "Let's Dance", "David Bowie - Let's Dance (2018 Remaster)", ""),
    ("love race (feat. Kellin Quinn)", "mgk", None, "mgk - love race (feat. Kellin Quinn) [Official Video]", ""),
    ("Car Radio (Ned's Version)", "twenty one pilots", None, "twenty one pilots - Car Radio (Ned's Version)", ""),
    ("Ride - Live in Mexico City", "twenty one pilots", None, "Ride (Live in Mexico City)", ""),
    ("Sluneční hrob", "Blue Effect", None, "Blue Effect - Sluneční hrob", ""),
    ("Dej lásku svou a hřej", "Kontrast", None, "Kontrast - Dej Lasku Svou A Hrej.mp3", ""),
    ("Damn Right, I've Got the Blues", "Buddy Guy", None, "02 Damn Right, I've Got The Blues.flac", ""),
    ("Can You Get to That (2026 Remastered)", "Funkadelic", None, "02-funkadelic-can_you_get_to_that_(2026_remastered).flac", ""),
    ("Elegy", "Leif Vollebekk", None, "Leif Vollebekk - Elegy (Official Audio)", ""),
    ("Dracula", "Tame Impala", None, "Tame Impala - Dracula (Official Video)", ""),
    ("Hodinový hotel", "Mňága a Žďorp", None, "Mňága a Žďorp - Hodinový hotel (oficiální video)", ""),
    ("A Forest", "The Cure", None, "The Cure - A Forest", ""),
    ("Old King", "Neil Young", "Harvest Moon", "Neil Young - Harvest Moon - 08 - Old King.flac", ""),
    # Pojmenování z lokální knihovny (scéna, weby, HTML entity, "&" v interpretovi):
    ("Cats And Dogs", "The Head and the Heart", None, "The-Head-And-The-Heart---Cats-And-Dogs.mp3", ""),
    ("Psi hvezda", "Květy", None, "01-kvety_-_psi_hvezda-mcz.mp3", ""),
    ("I used to dream", "Broken Records", None, "07-Broken_Records-I_used_to_dream-HFr.mp3", ""),
    ("Draw Your Swords", "Angus & Julia Stone", None, "www.NewAlbumReleases.net_11 - Draw Your Swords.mp3", "Down The Way"),
    ("Little Whiskey", "Angus & Julia Stone", None, "08 - Little Whiskey_[plixid.com].mp3", ""),
    ("Bella", "Angus & Julia Stone", None, "05-angus_and_julia_stone-bella.mp3", "A Book Like This"),
    ("Black Widow", "Mandolin Orange", None, "Mandolin Orange - &quot;Black Widow&quot;.mp3", ""),
    ("Won’t Let You Go", "Dope Lemon", None, "09. Wont Let You Go.mp3", ""),
    ("Song for a Winter's Night", "Tony Rice", None, "CD 1 - 06 - Song for a winters night.mp3", ""),
    ("Lenslife", "Fanfarlo", None, "03 Lens Life.mp3", ""),
    # Falešná odmítnutí z ověření na skutečných souborech knihovny:
    ("RAWFEAR", "twenty one pilots", "Breach", "0102 - RAWFEAR.flac", "twenty one pilots - Album - 2025 - Breach"),
    ("One Way", "twenty one pilots", "Breach", "10-One_Way.flac", "2025-Breach"),
    ("Drum Show", "twenty one pilots", None, "twenty one pilots - Breach - 03 Drum Show.flac", "[2025] Breach"),
    ("From The Start", "Laufey", None, "Laufey - Bewitched - 10 From the Start.flac", "[2023] Bewitched"),
    ("I'm Your Hoochie Coochie Man", "Muddy Waters", None, "22 - (I’m Your) Hoochie Coochie Man.flac", "Disc 01"),
    (
        "Dance of the Dream Man (Instrumental)", "Angelo Badalamenti", "Soundtrack From Twin Peaks",
        "9 - Dance of the Dream Man.flac", "1990 - Soundtrack From Twin Peaks",
    ),
    ("Back Door Man", "Howlin' Wolf", None, "02x18 - Back Door Man.flac", "Howlin’ Wolf - The Chess Box (1991) (Multi Disc)"),
    ("I'm In The Mood", "John Lee Hooker", None, "01. I'm In The Mood.mp3", "1966 - The Complete Chess Folk Blues Sessions (Remastered 1991)"),
    (
        "I Ain't Superstitious", "Howlin' Wolf", "The London Howlin' Wolf Sessions",
        "Howlin’ Wolf featuring Eric Clapton, Steve Winwood - The London Howlin’ Wolf Sessions - 02 - I Ain’t Superstitious.flac",
        "The London Howlin’ Wolf Sessions (1971)",
    ),
]


@pytest.mark.parametrize("title,artist,album,label,context", WRONG)
def test_wrong_candidates_rejected(title, artist, album, label, context):
    assert match_label(title, label, artist=artist, album=album, context=context) is not None


@pytest.mark.parametrize("title,artist,album,label,context", RIGHT)
def test_right_candidates_accepted(title, artist, album, label, context):
    assert match_label(title, label, artist=artist, album=album, context=context) is None


def test_cjk_titles_have_tokens():
    assert tokens("雨の中で")


def test_artist_check():
    assert not artist_in("Future", "SPARKLEWOLF RADIO - 21 in the near")
    assert artist_in("The Cure", "Music\\Cure, The\\Disintegration\\01 Plainsong.flac")
    assert artist_in("Mňága a Žďorp", "Mnaga a Zdorp - Hodinovy hotel")
    assert artist_in("AURORA;Pomme", "AURORA - Everything Matters")


def test_duration():
    assert duration_ok(240, 243)
    assert not duration_ok(240, 252)
    assert duration_ok(240, 252, strict=False)
    assert not duration_ok(None, 240)
