"""Filmy a seriály -- stejná stránka jako hry (app/games.py, `Catalog`):
franšízy jako "interpret" (Harry Potter, Pán prstenů, Star Wars...), velké
obrázky (plakát z Wikipedie), skladatelé, mixy a řady. Soundtrack se bere
jen od skladatele nebo oficiálního vydavatele, ze stejného dílu."""

from __future__ import annotations

from app.games import Catalog, Game

SERIES: dict[str, tuple[str, str]] = {
    "harry-potter": ("Harry Potter", "#7A2E2E"),
    "lotr": ("Pán prstenů a Hobit", "#5B6B3A"),
    "star-wars": ("Star Wars", "#1E2A44"),
    "marvel": ("Marvel", "#B3242B"),
    "nolan": ("Christopher Nolan", "#2B3A4A"),
    "dune": ("Duna", "#B07A3A"),
    "ghibli": ("Studio Ghibli", "#4A8A9A"),
    "dollars": ("Dolarová trilogie a Leone", "#8A5A2B"),
    "godfather": ("Kmotr", "#3A2A1E"),
    "jurassic": ("Jurský park", "#3F6A2B"),
    "back-to-future": ("Návrat do budoucnosti", "#C26A1E"),
    "pirates": ("Piráti z Karibiku", "#2B4A5A"),
}

MOVIES: list[Game] = [
    # Harry Potter
    Game("hp-1", "Harry Potter and the Philosopher's Stone", 2001, ("John Williams",), "harry-potter",
         wiki="Harry Potter and the Philosopher's Stone (film)", album="Harry Potter and the Sorcerer's Stone", tags=("epic", "fantasy")),
    Game("hp-2", "Harry Potter and the Chamber of Secrets", 2002, ("John Williams",), "harry-potter",
         wiki="Harry Potter and the Chamber of Secrets (film)", tags=("fantasy",)),
    Game("hp-3", "Harry Potter and the Prisoner of Azkaban", 2004, ("John Williams",), "harry-potter",
         wiki="Harry Potter and the Prisoner of Azkaban (film)", tags=("fantasy",)),
    Game("hp-4", "Harry Potter and the Goblet of Fire", 2005, ("Patrick Doyle",), "harry-potter",
         wiki="Harry Potter and the Goblet of Fire (film)", tags=("fantasy",)),
    Game("hp-5", "Harry Potter and the Order of the Phoenix", 2007, ("Nicholas Hooper",), "harry-potter",
         wiki="Harry Potter and the Order of the Phoenix (film)", tags=("fantasy",)),
    Game("hp-6", "Harry Potter and the Half-Blood Prince", 2009, ("Nicholas Hooper",), "harry-potter",
         wiki="Harry Potter and the Half-Blood Prince (film)", tags=("fantasy",)),
    Game("hp-7", "Harry Potter and the Deathly Hallows – Part 1", 2010, ("Alexandre Desplat",), "harry-potter",
         wiki="Harry Potter and the Deathly Hallows – Part 1", album="Harry Potter and the Deathly Hallows, Pt. 1", tags=("fantasy",)),
    Game("hp-8", "Harry Potter and the Deathly Hallows – Part 2", 2011, ("Alexandre Desplat",), "harry-potter",
         wiki="Harry Potter and the Deathly Hallows – Part 2", album="Harry Potter and the Deathly Hallows, Pt. 2", tags=("epic", "fantasy")),
    # Pán prstenů a Hobit
    Game("lotr-1", "The Lord of the Rings: The Fellowship of the Ring", 2001, ("Howard Shore",), "lotr",
         wiki="The Lord of the Rings: The Fellowship of the Ring", tags=("epic", "fantasy")),
    Game("lotr-2", "The Lord of the Rings: The Two Towers", 2002, ("Howard Shore",), "lotr",
         wiki="The Lord of the Rings: The Two Towers", tags=("epic", "fantasy")),
    Game("lotr-3", "The Lord of the Rings: The Return of the King", 2003, ("Howard Shore",), "lotr",
         wiki="The Lord of the Rings: The Return of the King", tags=("epic", "fantasy")),
    Game("hobbit-1", "The Hobbit: An Unexpected Journey", 2012, ("Howard Shore",), "lotr",
         wiki="The Hobbit: An Unexpected Journey", tags=("fantasy",)),
    Game("hobbit-2", "The Hobbit: The Desolation of Smaug", 2013, ("Howard Shore",), "lotr",
         wiki="The Hobbit: The Desolation of Smaug", tags=("fantasy",)),
    Game("hobbit-3", "The Hobbit: The Battle of the Five Armies", 2014, ("Howard Shore",), "lotr",
         wiki="The Hobbit: The Battle of the Five Armies", tags=("epic", "fantasy")),
    # Star Wars
    Game("sw-4", "Star Wars: A New Hope", 1977, ("John Williams",), "star-wars", wiki="Star Wars (film)", tags=("epic", "classic")),
    Game("sw-5", "Star Wars: The Empire Strikes Back", 1980, ("John Williams",), "star-wars",
         wiki="The Empire Strikes Back", tags=("epic", "classic")),
    Game("sw-6", "Star Wars: Return of the Jedi", 1983, ("John Williams",), "star-wars", wiki="Return of the Jedi", tags=("epic",)),
    Game("sw-7", "Star Wars: The Force Awakens", 2015, ("John Williams",), "star-wars", wiki="Star Wars: The Force Awakens", tags=("epic",)),
    Game("rogue-one", "Rogue One: A Star Wars Story", 2016, ("Michael Giacchino",), "star-wars", wiki="Rogue One", tags=("epic",)),
    Game("mandalorian", "The Mandalorian", 2019, ("Ludwig Göransson",), "star-wars", wiki="The Mandalorian", album="The Mandalorian: Chapter 1", tags=("tv",)),
    # Marvel
    Game("avengers", "The Avengers", 2012, ("Alan Silvestri",), "marvel", wiki="The Avengers (2012 film)", tags=("epic",)),
    Game("guardians", "Guardians of the Galaxy", 2014, ("Tyler Bates",), "marvel",
         wiki="Guardians of the Galaxy (film)", extra_albums=("Guardians of the Galaxy: Awesome Mix Vol. 1",), tags=("roadtrip",),
         stations=("Awesome Mix Vol. 1",), hints=("guardians", "galaxy"), stations_title="Soundtrack (písně)"),
    Game("infinity-war", "Avengers: Infinity War", 2018, ("Alan Silvestri",), "marvel", wiki="Avengers: Infinity War", tags=("epic",)),
    Game("endgame", "Avengers: Endgame", 2019, ("Alan Silvestri",), "marvel", wiki="Avengers: Endgame", tags=("epic",)),
    Game("black-panther", "Black Panther", 2018, ("Ludwig Göransson",), "marvel", wiki="Black Panther (film)", tags=("epic",)),
    # Nolan / Zimmer
    Game("dark-knight", "The Dark Knight", 2008, ("Hans Zimmer", "James Newton Howard"), "nolan", wiki="The Dark Knight", tags=("thriller",)),
    Game("inception", "Inception", 2010, ("Hans Zimmer",), "nolan", wiki="Inception", tags=("thriller", "epic")),
    Game("interstellar", "Interstellar", 2014, ("Hans Zimmer",), "nolan", wiki="Interstellar (film)", tags=("epic",)),
    Game("oppenheimer", "Oppenheimer", 2023, ("Ludwig Göransson",), "nolan", wiki="Oppenheimer (film)", tags=("new", "thriller")),
    Game("dune-1", "Dune", 2021, ("Hans Zimmer",), "dune", wiki="Dune (2021 film)", tags=("epic",)),
    Game("dune-2", "Dune: Part Two", 2024, ("Hans Zimmer",), "dune", wiki="Dune: Part Two", tags=("epic", "new")),
    Game("gladiator", "Gladiator", 2000, ("Hans Zimmer", "Lisa Gerrard"), None, wiki="Gladiator (2000 film)", tags=("epic",)),
    Game("lion-king", "The Lion King", 1994, ("Hans Zimmer",), None, wiki="The Lion King", tags=("animated", "classic")),
    Game("pirates", "Pirates of the Caribbean: The Curse of the Black Pearl", 2003, ("Klaus Badelt", "Hans Zimmer"), "pirates",
         wiki="Pirates of the Caribbean: The Curse of the Black Pearl", tags=("epic",)),
    Game("pirates-2", "Pirates of the Caribbean: Dead Man's Chest", 2006, ("Hans Zimmer",), "pirates",
         wiki="Pirates of the Caribbean: Dead Man's Chest", tags=("epic",)),
    # Studio Ghibli (Joe Hisaishi -- japonská vydání)
    Game("spirited-away", "Spirited Away", 2001, ("Joe Hisaishi",), "ghibli", wiki="Spirited Away", tags=("animated",)),
    Game("mononoke", "Princess Mononoke", 1997, ("Joe Hisaishi",), "ghibli", wiki="Princess Mononoke", tags=("animated", "epic")),
    Game("howl", "Howl's Moving Castle", 2004, ("Joe Hisaishi",), "ghibli", wiki="Howl's Moving Castle (film)", tags=("animated",)),
    Game("totoro", "My Neighbor Totoro", 1988, ("Joe Hisaishi",), "ghibli", wiki="My Neighbor Totoro", tags=("animated",)),
    # Klasika
    Game("good-bad-ugly", "The Good, the Bad and the Ugly", 1966, ("Ennio Morricone",), "dollars",
         wiki="The Good, the Bad and the Ugly", tags=("classic", "roadtrip")),
    Game("once-upon-west", "Once Upon a Time in the West", 1968, ("Ennio Morricone",), "dollars",
         wiki="Once Upon a Time in the West", tags=("classic",)),
    Game("godfather", "The Godfather", 1972, ("Nino Rota",), "godfather", wiki="The Godfather", tags=("classic",)),
    Game("godfather-2", "The Godfather Part II", 1974, ("Nino Rota", "Carmine Coppola"), "godfather", wiki="The Godfather Part II", tags=("classic",)),
    Game("jaws", "Jaws", 1975, ("John Williams",), None, wiki="Jaws (film)", tags=("classic", "horror")),
    Game("et", "E.T. the Extra-Terrestrial", 1982, ("John Williams",), None, wiki="E.T. the Extra-Terrestrial", tags=("classic",)),
    Game("jurassic-park", "Jurassic Park", 1993, ("John Williams",), "jurassic", wiki="Jurassic Park (film)", tags=("classic", "epic")),
    Game("schindler", "Schindler's List", 1993, ("John Williams",), None, wiki="Schindler's List", tags=("classic",)),
    Game("bttf", "Back to the Future", 1985, ("Alan Silvestri",), "back-to-future", wiki="Back to the Future", tags=("classic", "roadtrip")),
    Game("forrest-gump", "Forrest Gump", 1994, ("Alan Silvestri",), None, wiki="Forrest Gump", tags=("classic", "roadtrip")),
    Game("titanic", "Titanic", 1997, ("James Horner",), None, wiki="Titanic (1997 film)", tags=("classic",)),
    Game("braveheart", "Braveheart", 1995, ("James Horner",), None, wiki="Braveheart", tags=("classic", "epic")),
    Game("shawshank", "The Shawshank Redemption", 1994, ("Thomas Newman",), None, wiki="The Shawshank Redemption", tags=("classic",)),
    Game("amelie", "Amélie", 2001, ("Yann Tiersen",), None, wiki="Amélie", album="Le fabuleux destin d'Amélie Poulain", tags=("classic",)),
    # Kompilační soundtracky (písně)
    Game("pulp-fiction", "Pulp Fiction", 1994, ("Various Artists",), None, wiki="Pulp Fiction",
         extra_albums=("Pulp Fiction",), tags=("roadtrip",)),
    Game("drive", "Drive", 2011, ("Cliff Martinez",), None, wiki="Drive (2011 film)", tags=("roadtrip", "thriller")),
    Game("baby-driver", "Baby Driver", 2017, ("Steven Price",), None, wiki="Baby Driver", extra_albums=("Baby Driver",), tags=("roadtrip",),
         stations=("Baby Driver soundtrack",), hints=("baby driver",), stations_title="Soundtrack (písně)"),
    # Horor a napětí
    Game("psycho", "Psycho", 1960, ("Bernard Herrmann",), None, wiki="Psycho (1960 film)", tags=("horror", "classic")),
    Game("halloween", "Halloween", 1978, ("John Carpenter",), None, wiki="Halloween (1978 film)", tags=("horror",)),
    Game("shining", "The Shining", 1980, ("Wendy Carlos", "Rachel Elkind"), None, wiki="The Shining (film)", tags=("horror",)),
    Game("suspiria", "Suspiria", 1977, ("Goblin",), None, wiki="Suspiria", tags=("horror",)),
    Game("stranger-things", "Stranger Things", 2016, ("Kyle Dixon", "Michael Stein"), None, wiki="Stranger Things", tags=("tv", "horror")),
    # Seriály
    Game("got", "Game of Thrones", 2011, ("Ramin Djawadi",), None, wiki="Game of Thrones", tags=("tv", "epic", "fantasy")),
    Game("westworld", "Westworld", 2016, ("Ramin Djawadi",), None, wiki="Westworld (TV series)", tags=("tv",)),
    Game("witcher-netflix", "The Witcher", 2019, ("Sonya Belousova", "Giona Ostinelli"), None, wiki="The Witcher (TV series)", tags=("tv", "fantasy")),
    Game("tlou-hbo", "The Last of Us", 2023, ("Gustavo Santaolalla", "David Fleming"), None, wiki="The Last of Us (TV series)", tags=("tv", "new")),
    Game("twin-peaks", "Twin Peaks", 1990, ("Angelo Badalamenti",), None, wiki="Twin Peaks", album="Soundtrack from Twin Peaks", tags=("tv", "classic")),
    Game("arcane", "Arcane", 2021, ("Various Artists",), None, wiki="Arcane (TV series)", album="Arcane League of Legends", tags=("tv", "animated")),
    # Česká filmová hudba
    Game("popelka", "Tři oříšky pro Popelku", 1973, ("Karel Svoboda",), None, wiki="Three Wishes for Cinderella", tags=("czech", "classic")),
    Game("limonadovy-joe", "Limonádový Joe", 1964, ("Jan Rychlík", "Vlastimil Hála"), None, wiki="Lemonade Joe", tags=("czech", "classic")),
    Game("kolja", "Kolja", 1996, ("Ondřej Soukup",), None, wiki="Kolya", tags=("czech",)),
    Game("sakali-leta", "Šakalí léta", 1993, ("Ondřej Soukup", "Jaroslav Uhlíř"), None, wiki="Big Beat (film)", tags=("czech",)),
    Game("pelisky", "Pelíšky", 1999, ("Jiří Bulis",), None, wiki="Cosy Dens", tags=("czech",)),
]

MIXES: dict[str, tuple[str, str, tuple[str, ...], tuple[str, ...]]] = {
    "epic": ("Epická filmová hudba", "Orchestr, sbor a velká témata", ("epic",), ()),
    "classic": ("Klasika filmové hudby", "Williams, Morricone, Rota, Horner", ("classic",), ()),
    "fantasy": ("Fantasy světy", "Středozemě, Bradavice, Západozemí", ("fantasy",), ()),
    "animated": ("Animované a Ghibli", "Hisaishi, Zimmer a další", ("animated",), ()),
    "roadtrip": ("Na cestu jako ve filmu", "Pulp Fiction, Baby Driver, Drive", ("roadtrip",), ()),
    "horror": ("Horor a napětí", "Carpenter, Herrmann, Goblin", ("horror", "thriller"), ()),
    "tv": ("Seriálové soundtracky", "Hra o trůny, Stranger Things, Twin Peaks", ("tv",), ()),
    "czech": ("Česká filmová hudba", "Svoboda, Soukup, Hála", ("czech",), ()),
}

LABELS = (
    "walt disney records", "hollywood records", "watertower music", "sony classical", "varese sarabande",
    "lakeshore records", "milan records", "decca", "netflix music", "hbo", "lucasfilm", "marvel music",
    "studio ghibli records", "tokuma japan", "supraphon", "universal pictures", "columbia",
)

SEQUEL = frozenset({
    "ii", "iii", "iv", "v", "vi", "2", "3", "4", "5", "6", "7", "8", "part", "chapter", "returns", "reloaded",
    "revolutions", "resurrection", "musical", "concert", "live", "broadway", "game", "video", "lego",
})

MOVIES_CATALOG = Catalog(
    ns="movies",
    items=MOVIES,
    series=SERIES,
    mixes=MIXES,
    labels=LABELS,
    sequel=SEQUEL,
    rows=(
        ("new", "Nové soundtracky", "new"),
        ("classic", "Klasika", "classic"),
        ("tv", "Seriály", "tv"),
        ("horror", "Horor a napětí", "horror"),
        ("czech", "Česká filmová hudba", "czech"),
    ),
    all_title="Všechny filmy a seriály",
    series_unit="filmů",
    page_version="v9",
    strict_core=True,
    ost_version="v8",
)
