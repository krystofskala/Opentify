"""Hry -- stránka herních soundtracků (Procházet › Herní soundtracky).

Kurátorský katalog her: série, skladatelé, rok, obrázek hry a soundtrack.

Obrázky bez účtů a klíčů:
- Steam (oficiální key art: `library_hero.jpg` přes celou šířku, obal
  `library_600x900.jpg`) -- id aplikace se OVĚŘÍ proti názvu hry ve Store
  API (špatné id = cizí hra, to nesmí projít),
- jinak hlavní obrázek článku na Wikipedii (hry Nintenda a další mimo Steam).

Soundtrack: album na Deezeru, jehož interpret je skladatel hry a název
obsahuje název hry (ne covery, piano verze ani lo-fi předělávky).
Vše se ukládá do cache (obrázky měsíc, stránka den).
"""

from __future__ import annotations

import os

import asyncio
import logging
import random
import re
from dataclasses import dataclass, field
from typing import Any

import httpx
from sqlmodel import Session

from app.catalog.cache import cached_json
from app.db import engine
from app.download_match import _covered, core_tokens, fold, tokens
from app.utils import utcnow

logger = logging.getLogger("vault.games")

MONTH = 30 * 24 * 3600
DAY = 24 * 3600
# Identifikace pro Wikipedii/Steam -- z .env (MUSICBRAINZ_USER_AGENT), ať se
# cizí instalace nehlásí cizím kontaktem.
_UA = {"User-Agent": os.environ.get("MUSICBRAINZ_USER_AGENT") or "Opentify/1.0"}


@dataclass(frozen=True)
class Game:
    slug: str
    title: str
    year: int
    composers: tuple[str, ...]
    series: str | None = None
    steam: int | None = None
    wiki: str | None = None  # název článku na en.wikipedia (obrázek mimo Steam)
    album: str | None = None  # nápověda názvu alba, když se jmenuje jinak než hra
    tags: tuple[str, ...] = field(default_factory=tuple)  # epic, calm, retro, indie, czech, new
    # Rádia ve hře (GTA): názvy stanic + slova, podle kterých se pozná hra
    # v názvu fanouškovského playlistu ("san andreas", "gta sa").
    stations: tuple[str, ...] = ()
    hints: tuple[str, ...] = ()
    # Další alba díla, hlavně soundtrack s písněmi ("Awesome Mix Vol. 1").
    extra_albums: tuple[str, ...] = ()
    # Nadpis playlistů ze `stations` (GTA: rádia; jinde soundtrack s písněmi,
    # když oficiální album u nás na streamování není).
    stations_title: str = "Rádia"
    series_title: str | None = None  # díla z Wikidat (série = QID)


# Série: id -> (název, barva)
SERIES: dict[str, tuple[str, str]] = {
    "zelda": ("The Legend of Zelda", "#3E8E5E"),
    "final-fantasy": ("Final Fantasy", "#3B5BA9"),
    "elder-scrolls": ("The Elder Scrolls", "#7A6A4F"),
    "witcher": ("Zaklínač", "#A33A2B"),
    "halo": ("Halo", "#2F6F4F"),
    "mass-effect": ("Mass Effect", "#2B4C7E"),
    "mario": ("Super Mario", "#D33A2C"),
    "metroid": ("Metroid", "#C2552B"),
    "kingdom-hearts": ("Kingdom Hearts", "#5B3FA0"),
    "souls": ("Souls (FromSoftware)", "#5A4A3A"),
    "doom": ("DOOM", "#9E2A1E"),
    "supergiant": ("Supergiant Games", "#B8862B"),
    "ori": ("Ori", "#2E7DA8"),
    "toby-fox": ("Undertale / Deltarune", "#C23A5A"),
    "nier": ("NieR", "#8A8A7A"),
    "persona": ("Persona", "#C21E2E"),
    "kingdom-come": ("Kingdom Come", "#8A6A2C"),
    "mafia": ("Mafia", "#3A3A3A"),
    "hollow-knight": ("Hollow Knight", "#3F5F7F"),
    "portal": ("Portal / Half-Life", "#D27A2B"),
    "red-dead": ("Red Dead", "#A8432B"),
    "gta": ("Grand Theft Auto", "#2E7D4F"),
}

GAMES: list[Game] = [
    # The Legend of Zelda (Nintendo -- obrázky z Wikipedie)
    Game("zelda-ocarina", "The Legend of Zelda: Ocarina of Time", 1998, ("Koji Kondo",), "zelda", wiki="The Legend of Zelda: Ocarina of Time", tags=("retro",)),
    Game("zelda-link-to-the-past", "The Legend of Zelda: A Link to the Past", 1991, ("Koji Kondo",), "zelda", wiki="The Legend of Zelda: A Link to the Past", tags=("retro",)),
    Game("zelda-botw", "The Legend of Zelda: Breath of the Wild", 2017, ("Manaka Kataoka", "Yasuaki Iwata", "Hajime Wakai"), "zelda", wiki="The Legend of Zelda: Breath of the Wild", tags=("calm",)),
    Game("zelda-totk", "The Legend of Zelda: Tears of the Kingdom", 2023, ("Manaka Kataoka", "Maasa Miyoshi"), "zelda", wiki="The Legend of Zelda: Tears of the Kingdom", tags=("epic",)),
    # Final Fantasy
    Game("ff6", "Final Fantasy VI", 1994, ("Nobuo Uematsu",), "final-fantasy", steam=1173820, tags=("retro", "epic")),
    Game("ff7", "Final Fantasy VII", 1997, ("Nobuo Uematsu",), "final-fantasy", steam=39140, tags=("retro", "epic")),
    Game("ff10", "Final Fantasy X", 2001, ("Nobuo Uematsu", "Masashi Hamauzu", "Junya Nakano"), "final-fantasy", steam=359870),
    Game("ff7-remake", "Final Fantasy VII Remake", 2020, ("Nobuo Uematsu", "Masashi Hamauzu", "Mitsuto Suzuki"), "final-fantasy", steam=1462040, tags=("epic",)),
    Game("ff16", "Final Fantasy XVI", 2023, ("Masayoshi Soken",), "final-fantasy", steam=2515020, tags=("epic", "new")),
    # The Elder Scrolls
    Game("morrowind", "The Elder Scrolls III: Morrowind", 2002, ("Jeremy Soule",), "elder-scrolls", steam=22320, tags=("calm",)),
    Game("oblivion", "The Elder Scrolls IV: Oblivion", 2006, ("Jeremy Soule",), "elder-scrolls", steam=22330, tags=("calm",)),
    Game("skyrim", "The Elder Scrolls V: Skyrim", 2011, ("Jeremy Soule",), "elder-scrolls", steam=72850, tags=("epic", "calm")),
    # Zaklínač
    Game("witcher-1", "The Witcher", 2007, ("Adam Skorupa", "Paweł Błaszczak"), "witcher", steam=20900, tags=("calm",)),
    Game("witcher-2", "The Witcher 2: Assassins of Kings", 2011, ("Adam Skorupa", "Krzysztof Wierzynkiewicz"), "witcher", steam=20920, tags=("epic",)),
    Game("witcher-3", "The Witcher 3: Wild Hunt", 2015, ("Marcin Przybyłowicz", "Mikolai Stroinski"), "witcher", steam=292030, tags=("epic",)),
    Game("cyberpunk", "Cyberpunk 2077", 2020, ("Marcin Przybyłowicz", "P.T. Adamczyk", "Paul Leonard-Morgan"), None, steam=1091500),
    # Halo
    Game("halo-ce", "Halo: Combat Evolved", 2001, ("Martin O'Donnell", "Michael Salvatori"), "halo", steam=976730, tags=("epic",)),
    Game("halo-3", "Halo 3", 2007, ("Martin O'Donnell", "Michael Salvatori"), "halo", wiki="Halo 3", tags=("epic",)),
    # Mass Effect
    Game("mass-effect", "Mass Effect", 2007, ("Jack Wall", "Sam Hulick"), "mass-effect", steam=1328670),
    # Super Mario, Metroid
    Game("mario-64", "Super Mario 64", 1996, ("Koji Kondo",), "mario", wiki="Super Mario 64", tags=("retro",)),
    Game("mario-galaxy", "Super Mario Galaxy", 2007, ("Mahito Yokota", "Koji Kondo"), "mario", wiki="Super Mario Galaxy", tags=("epic",)),
    Game("metroid-prime", "Metroid Prime", 2002, ("Kenji Yamamoto", "Kouichi Kyuma"), "metroid", wiki="Metroid Prime", tags=("calm",)),
    # Kingdom Hearts
    Game("kingdom-hearts", "Kingdom Hearts", 2002, ("Yoko Shimomura",), "kingdom-hearts", wiki="Kingdom Hearts (video game)"),
    # Souls
    Game("dark-souls-3", "Dark Souls III", 2016, ("Motoi Sakuraba", "Yuka Kitamura"), "souls", steam=374320, tags=("epic",)),
    Game("elden-ring", "Elden Ring", 2022, ("Tsukasa Saitoh", "Shoi Miyazawa", "Yuka Kitamura"), "souls", steam=1245620, tags=("epic",)),
    # DOOM
    Game("doom-2016", "DOOM", 2016, ("Mick Gordon",), "doom", steam=379720, tags=("epic",)),
    Game("doom-eternal", "DOOM Eternal", 2020, ("Mick Gordon",), "doom", steam=782330, tags=("epic",)),
    # Supergiant
    Game("bastion", "Bastion", 2011, ("Darren Korb",), "supergiant", steam=107100, tags=("indie",)),
    Game("transistor", "Transistor", 2014, ("Darren Korb",), "supergiant", steam=237930, tags=("indie", "calm")),
    Game("hades", "Hades", 2020, ("Darren Korb",), "supergiant", steam=1145360, tags=("indie", "epic")),
    Game("hades-2", "Hades II", 2025, ("Darren Korb",), "supergiant", steam=1145350, tags=("indie", "new")),
    # Ori
    Game("ori-blind-forest", "Ori and the Blind Forest", 2015, ("Gareth Coker",), "ori", steam=387290, tags=("indie", "calm")),
    Game("ori-wisps", "Ori and the Will of the Wisps", 2020, ("Gareth Coker",), "ori", steam=1057090, tags=("indie", "epic")),
    # Toby Fox
    Game("undertale", "Undertale", 2015, ("Toby Fox",), "toby-fox", steam=391540, tags=("indie", "retro")),
    Game("deltarune", "Deltarune", 2018, ("Toby Fox",), "toby-fox", steam=1671210, album="Deltarune Chapter 1", tags=("indie", "retro")),
    # NieR, Persona
    Game("nier-automata", "NieR:Automata", 2017, ("Keiichi Okabe",), "nier", steam=524220, tags=("epic",)),
    Game("persona-5", "Persona 5", 2016, ("Shoji Meguro",), "persona", steam=1687950),
    # Hollow Knight
    Game("hollow-knight", "Hollow Knight", 2017, ("Christopher Larkin",), "hollow-knight", steam=367520, tags=("indie", "calm")),
    Game("silksong", "Hollow Knight: Silksong", 2025, ("Christopher Larkin",), "hollow-knight", steam=1030300, tags=("indie", "new")),
    # Portal / Half-Life
    Game("half-life-2", "Half-Life 2", 2004, ("Kelly Bailey",), "portal", steam=220),
    Game("portal-2", "Portal 2", 2011, ("Mike Morasky",), "portal", steam=620),
    # Red Dead
    Game("rdr2", "Red Dead Redemption 2", 2018, ("Woody Jackson",), "red-dead", steam=1174180, tags=("calm",)),
    # Grand Theft Auto -- hlavně rádia (Rockstar je nestreamuje -- skladby
    # z nejlepšího fanouškovského playlistu každé stanice)
    Game("gta-3", "Grand Theft Auto III", 2001, ("Rockstar Games",), "gta", steam=12100, tags=("retro",),
         stations=("Flashback 95.6", "Double Clef FM", "K-Jah", "Rise FM", "Lips 106", "Game Radio FM", "MSX FM", "Head Radio"),
         hints=("gta 3", "gta iii", "gta3", "grand theft auto iii", "grand theft auto 3", "liberty city")),
    Game("gta-vc", "Grand Theft Auto: Vice City", 2002, ("Rockstar Games",), "gta", steam=12110, tags=("retro",),
         stations=("Flash FM", "V-Rock", "Wildstyle", "Fever 105", "Emotion 98.3", "Wave 103", "Radio Espantoso", "VRock"),
         hints=("vice city", "gta vc", "gtavc")),
    Game("gta-sa", "Grand Theft Auto: San Andreas", 2004, ("Rockstar Games",), "gta", steam=12120, tags=("retro",),
         stations=("Radio Los Santos", "K-DST", "Bounce FM", "CSR 103.9", "K-Rose", "Radio X", "SF-UR", "Playback FM",
                   "Master Sounds 98.3", "K-Jah West"),
         hints=("san andreas", "gta sa", "gtasa")),
    Game("gta-4", "Grand Theft Auto IV", 2008, ("Michael Hunter",), "gta", steam=12210,
         stations=("Liberty Rock Radio", "The Journey", "Vladivostok FM", "Electro-Choc", "The Beat 102.7",
                   "Liberty City Hardcore", "Fusion FM", "Massive B", "IF99", "Radio Broker"),
         hints=("gta 4", "gta iv", "gta4", "grand theft auto iv", "grand theft auto 4")),
    Game("gta-5", "Grand Theft Auto V", 2013, ("Tangerine Dream", "Woody Jackson", "The Alchemist", "Oh No"), "gta", steam=271590,
         album="The Music of Grand Theft Auto V", tags=("new",),
         stations=("Non-Stop-Pop FM", "Los Santos Rock Radio", "West Coast Classics", "Radio Los Santos", "FlyLo FM",
                   "Channel X", "Rebel Radio", "Space 103.2", "The Lowdown 91.1", "Vinewood Boulevard Radio", "Soulwax FM",
                   "WorldWide FM", "East Los FM", "Radio Mirror Park", "The Blue Ark", "Blonded Los Santos 97.8"),
         hints=("gta 5", "gta v", "gta5", "gtav", "grand theft auto v", "grand theft auto 5", "gta online")),
    # Česká stopa
    Game("kcd", "Kingdom Come: Deliverance", 2018, ("Jan Valta", "Adam Sporka"), "kingdom-come", steam=379430, tags=("czech", "epic")),
    Game("kcd2", "Kingdom Come: Deliverance II", 2025, ("Jan Valta",), "kingdom-come", steam=1771300, tags=("czech", "new", "epic")),
    Game("mafia", "Mafia", 2002, ("Jesse Harlin", "Vladimír Šimůnek"), "mafia", steam=1030840, album="Mafia: Definitive Edition", tags=("czech",)),
    Game("mafia-2", "Mafia II", 2010, ("Matúš Široký",), "mafia", steam=1030830, tags=("czech",)),
    Game("machinarium", "Machinarium", 2009, ("Tomáš Dvořák",), None, steam=40700, tags=("czech", "indie", "calm")),
    # Indie klenoty
    Game("celeste", "Celeste", 2018, ("Lena Raine",), None, steam=504230, tags=("indie",)),
    Game("journey", "Journey", 2012, ("Austin Wintory",), None, steam=638230, tags=("indie", "calm")),
    Game("stardew", "Stardew Valley", 2016, ("ConcernedApe",), None, steam=413150, tags=("indie", "calm")),
    Game("outer-wilds", "Outer Wilds", 2019, ("Andrew Prahlow",), None, steam=753640, tags=("indie", "calm")),
    Game("minecraft", "Minecraft", 2011, ("C418",), None, wiki="Minecraft", album="Minecraft - Volume Alpha", tags=("calm",)),
    Game("terraria", "Terraria", 2011, ("Scott Lloyd Shelly",), None, steam=105600, tags=("indie", "retro")),
    Game("cuphead", "Cuphead", 2017, ("Kristofer Maddigan",), None, steam=268910, tags=("indie",)),
    Game("disco-elysium", "Disco Elysium", 2019, ("Sea Power",), None, steam=632470, tags=("indie", "calm")),
    Game("katana-zero", "Katana ZERO", 2019, ("LudoWic", "Bill Kiley"), None, steam=460950, tags=("indie",)),
    Game("hotline-miami", "Hotline Miami", 2012, ("M|O|O|N", "Scattle", "Jasper Byrne"), None, steam=219150, tags=("indie", "retro")),
    Game("fez", "Fez", 2012, ("Disasterpeace",), None, steam=224760, tags=("indie", "retro", "calm")),
    Game("balatro", "Balatro", 2024, ("LouisF",), None, steam=2379780, tags=("indie", "new")),
    # Legendy 8/16-bit
    Game("chrono-trigger", "Chrono Trigger", 1995, ("Yasunori Mitsuda", "Nobuo Uematsu"), None, steam=613830, tags=("retro", "epic")),
    Game("sonic-mania", "Sonic Mania", 2017, ("Tee Lopes",), None, steam=584400, tags=("retro",)),
    Game("shovel-knight", "Shovel Knight", 2014, ("Jake Kaufman",), None, steam=250760, tags=("retro", "indie")),
    # Velké příběhy
    Game("god-of-war", "God of War", 2018, ("Bear McCreary",), None, steam=1593500, tags=("epic",)),
    Game("last-of-us", "The Last of Us", 2013, ("Gustavo Santaolalla",), None, steam=1888930, wiki="The Last of Us", tags=("calm",)),
    Game("death-stranding", "Death Stranding", 2019, ("Ludvig Forssell",), None, steam=1190460, tags=("calm",)),
    Game("baldurs-gate-3", "Baldur's Gate 3", 2023, ("Borislav Slavov",), None, steam=1086940, tags=("epic", "new")),
    Game("silent-hill-2", "Silent Hill 2", 2001, ("Akira Yamaoka",), None, wiki="Silent Hill 2", tags=("calm",)),
]
_BY_SLUG = {g.slug: g for g in GAMES}

# Herní mixy: id -> (název, popis, štítky her, slova v názvech skladeb)
GAME_MIXES: dict[str, tuple[str, str, tuple[str, ...], tuple[str, ...]]] = {
    "boss": ("Souboje s bossy", "Finální souboje a nejtěžší bitvy", ("epic",), ("boss", "battle", "fight", "vs", "versus", "showdown", "final", "duel")),
    "explore": ("Klidné prozkoumávání", "Otevřené světy, les a hvězdy", ("calm",), ()),
    "retro": ("Legendy 8/16-bit", "Chiptune a klasika ze 16bitové éry", ("retro",), ()),
    "epic": ("Orchestrální eposy", "Velké téma, sbor a orchestr", ("epic",), ("theme", "main", "title", "overture", "dragonborn")),
    "indie": ("Indie klenoty", "Malá studia, velká hudba", ("indie",), ()),
    "czech": ("Česká stopa", "Kingdom Come, Mafia, Machinarium", ("czech",), ()),
}


def get(slug: str) -> Game | None:
    return _BY_SLUG.get(slug)


# ----------------------------------------------------------------------
# Obrázky
# ----------------------------------------------------------------------


async def _steam_ok(game: Game) -> bool:
    """Patří Steam id opravdu téhle hře? (Store API, název hry v názvu aplikace.)"""

    async def fetch() -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=10.0, headers=_UA) as client:
            r = await client.get("https://store.steampowered.com/api/appdetails", params={"appids": game.steam, "filters": "basic"})
        data = (r.json() or {}).get(str(game.steam)) or {}
        return {"name": ((data.get("data") or {}).get("name") or "") if data.get("success") else ""}

    try:
        info = await cached_json(f"games:steam:{game.steam}", MONTH, fetch, is_empty=lambda v: not v.get("name"))
    except Exception:  # noqa: BLE001
        return False
    name_words = set(tokens(info.get("name") or ""))
    return bool(name_words) and all(_covered(w, name_words) for w in core_tokens(game.title))


async def _url_exists(url: str) -> bool:
    async def fetch() -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=10.0, headers=_UA, follow_redirects=True) as client:
            r = await client.head(url)
        return {"ok": r.status_code == 200 and r.headers.get("content-type", "").startswith("image/")}

    try:
        return bool((await cached_json(f"games:img:{url}", MONTH, fetch)).get("ok"))
    except Exception:  # noqa: BLE001
        return False


async def _wiki_image(title: str) -> str | None:
    async def fetch() -> dict[str, Any]:
        async with httpx.AsyncClient(timeout=10.0, headers=_UA, follow_redirects=True) as client:
            r = await client.get(f"https://en.wikipedia.org/api/rest_v1/page/summary/{title.replace(' ', '_')}")
        data = r.json() if r.status_code == 200 else {}
        img = data.get("originalimage") or data.get("thumbnail") or {}
        return {"url": img.get("source"), "width": int(img.get("width") or 0)}

    try:
        hit = await cached_json(f"games:wiki2:{title}", MONTH, fetch, is_empty=lambda v: not v.get("url"))
    except Exception:  # noqa: BLE001
        return None
    # Plakáty na anglické Wikipedii jsou kvůli právům malé (~250 px) -- po
    # zvětšení rozmazané; takové jen jako nouzovka (viz `game_card`).
    return hit.get("url") if hit.get("url") else None


async def _wiki_width(title: str) -> int:
    try:
        hit = await cached_json(f"games:wiki2:{title}", MONTH, lambda: _none(), is_empty=lambda v: not v.get("url"))
    except Exception:  # noqa: BLE001
        return 0
    return int(hit.get("width") or 0)


async def _none() -> dict[str, Any]:
    return {}


async def images(game: Game) -> dict[str, str | None]:
    """{"hero": široký obrázek, "cover": obal na výšku}."""
    hero = cover = None
    if game.steam and await _steam_ok(game):
        base = f"https://cdn.akamai.steamstatic.com/steam/apps/{game.steam}"
        for candidate in (f"{base}/library_hero.jpg", f"{base}/header.jpg"):
            if await _url_exists(candidate):
                hero = candidate
                break
        portrait = f"{base}/library_600x900.jpg"
        cover = portrait if await _url_exists(portrait) else hero
    lowres = False
    if hero is None:
        wiki = await _wiki_image(game.wiki or game.title)
        hero = cover = wiki
        lowres = bool(wiki) and await _wiki_width(game.wiki or game.title) < 800
    return {"hero": hero, "cover": cover, "lowres": lowres}


# ----------------------------------------------------------------------
# Soundtrack
# ----------------------------------------------------------------------

_NOT_OST = ("piano", "lofi", "lo-fi", "cover", "covers", "tribute", "remix", "remixes", "acoustic", "guitar", "8-bit version",
            "orchestral covers", "karaoke", "relax", "sleep", "chill", "trailer", "best soundtracks", "inspired by",
            "[live]", "(live)", "bedtime", "lullaby", "one piano")
# Jiný díl / jiné dílo: číslo, římská číslice, pokračování, film.
_SEQUEL = {
    "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii", "xiii", "xiv", "xv", "xvi", "2", "3", "4", "5", "6",
    "7", "8", "9", "10",  # II-X převádí `_words` na číslice
    "part", "chapter", "movie", "film", "nightreign", "remake", "rebirth", "reborn", "origins", "dlc", "expansion", "dungeons",
    "odst", "reach", "season", "hbo", "tv", "series", "anime",
}
# Oficiální vydavatelé herní hudby (soundtrack nevydaný pod jménem skladatele).
_LABELS = (
    "square enix music", "nintendo", "atlus game music", "fromsoftware sound team", "re-logic", "sega", "capcom",
    "konami", "bethesda", "xbox music", "halo", "aperture science", "bandai namco", "supergiant games",
    "cd projekt red", "rockstar games", "warhorse studios", "2k", "mojang", "sony interactive", "valve",
)


# Slova, která v názvu alba nevadí (vydání, ne jiné dílo).
_CORE_OK = {
    "the", "of", "a", "and", "original", "motion", "picture", "soundtrack", "score", "music", "from", "ost", "complete",
    "edition", "deluxe", "expanded", "anniversary", "remastered", "version", "vol", "volume", "1", "official", "series",
    "netflix", "hbo", "season", "songs", "theme", "themes", "tv", "television", "film", "movie", "collection",
}


_ROMAN = {"ii": "2", "iii": "3", "iv": "4", "v": "5", "vi": "6", "vii": "7", "viii": "8", "ix": "9", "x": "10"}
_GLUED = re.compile(r"^([^\W\d_]{3,})(\d{1,2})$")


def _words(text: str) -> list[str]:
    """Slova názvu; římské II-X jako číslice ("Dark Souls III" = "Dark Souls 3")
    a slepené číslo dílu zvlášť ("SILENT HILL2" -> "hill", "2")."""
    out: list[str] = []
    for w in tokens(text.replace(":", " ").replace("-", " ")):
        glued = _GLUED.match(w)
        out.extend(glued.groups() if glued else (_ROMAN.get(w, w),))
    return out


def _same_work(want: list[str], title_words: set[str], words: list[str], sequel: frozenset[str]) -> bool:
    """Album patří k dílu: má všechna jeho slova a žádné slovo jiného dílu
    (Dark Souls 3 není Dark Souls 2)."""
    if not all(_covered(w, set(words)) for w in want):
        return False
    return not ({w for w in words if w in sequel} - title_words)


@dataclass(frozen=True)
class Catalog:
    """Sada děl se soundtracky -- hry, filmy a seriály (app/movies.py)."""

    ns: str  # klíče cache, zdroje playlistů, cesty v appce
    items: list[Game]
    series: dict[str, tuple[str, str]]
    mixes: dict[str, tuple[str, str, tuple[str, ...], tuple[str, ...]]]
    labels: tuple[str, ...]
    sequel: frozenset[str]
    rows: tuple[tuple[str, str, str], ...]  # (id, název, štítek)
    all_title: str
    series_unit: str  # "her" / "filmů"
    page_version: str = "v1"
    # Název alba (před závorkou) nesmí mít slovo navíc oproti dílu -- u filmů
    # "Avengers: Endgame" není "The Avengers", "Halloween Ends" není "Halloween".
    strict_core: bool = False
    ost_version: str = "v1"


async def soundtracks(game: Game, cat: Catalog | None = None) -> list[dict[str, str]]:
    """Alba díla: [{"id", "kind"}] -- "score" (hudba skladatele / oficiální
    vydavatel) a "songs" (oficiální kompilace písní, které v díle zazní,
    "Various Artists"). Jako na CD/LP: dvě desky. Jen stejné dílo, žádné
    covery/piano/lo-fi; radši nic než cizí album."""
    from app.catalog.deezer import get_deezer_client
    from app.catalog.deezer_ingest import ingest_album, ingest_artist

    cat = cat or GAMES_CATALOG
    version = "v9" if cat.ns == "games" else cat.ost_version

    async def fetch() -> dict[str, Any]:
        dz = get_deezer_client()
        picks: dict[str, tuple[int, dict[str, Any]]] = {}
        names = [(game.album or game.title, None), *((n, "songs") for n in game.extra_albums)]
        for name, forced in names:
            want = [w for w in _words(name) if w not in ("the", "of", "a", "and")]
            title_words = set(_words(game.title)) | set(_words(name))
            composers = {fold(c) for c in game.composers if c}
            first = next((c for c in game.composers if c), "")
            for q in dict.fromkeys((f"{name} soundtrack", f"{first} {name}".strip(), name)):
                hits = await dz._cached_data(f"dz:search_album_q:{q}", MONTH, "/search/album", {"q": q, "limit": 25}) or []
                for h in hits:
                    title = h.get("title") or ""
                    artist = fold((h.get("artist") or {}).get("name") or "")
                    words = _words(title)
                    if not _same_work(want, title_words, words, cat.sequel):
                        continue
                    if cat.strict_core:
                        core = re.split(r"[\(\[]| - | – ", title)[0]
                        if set(_words(core)) - set(want) - _CORE_OK:
                            continue
                    low = fold(title)
                    if any(bad in low for bad in _NOT_OST):
                        continue
                    # Rok v názvu jiný než rok díla = jiný díl / remake ("God of War (2005)").
                    if any(abs(int(y) - game.year) > 1 for y in re.findall(r"\b(?:19|20)\d{2}\b", title) if y not in game.title):
                        continue
                    tracks = int(h.get("nb_tracks") or 0)
                    if tracks and tracks < 5:
                        continue
                    is_various = artist == "various artists"
                    by_composer = not is_various and any(c in artist or (artist and artist in c) for c in composers)
                    by_label = not is_various and any(label in artist for label in cat.labels)
                    # Oficiální kompilace písní -- jen s přesným názvem díla,
                    # oficiálním označením a 10+ skladbami.
                    by_various = (
                        is_various
                        and tracks >= 10
                        and (
                            forced == "songs"
                            or any(w in low for w in ("original motion picture soundtrack", "original soundtrack",
                                                      "music from the motion picture", "original game soundtrack",
                                                      "soundtrack from the", "music from the"))
                        )
                    )
                    # Dílo bez známého skladatele (z Wikidat/Steamu): album s přesně
                    # tímhle názvem a oficiálním označením ("X (Original Soundtrack)").
                    by_exact = False
                    if not composers and not is_various and tracks >= 5:
                        core = re.split(r"[\(\[]| - | – ", title)[0]
                        by_exact = not (set(_words(core)) - set(want) - _CORE_OK) and any(
                            w in low for w in ("original soundtrack", "original game soundtrack", "original score", "ost")
                        )
                    if not (by_composer or by_label or by_various or by_exact):
                        continue
                    kind = forced or ("songs" if is_various else "score")
                    official = any(w in low for w in ("original", "soundtrack", "ost", "score", "music from", "motion picture"))
                    rank = (3 if by_composer else 1) + (1 if official else 0)
                    if kind not in picks or rank > picks[kind][0]:
                        picks[kind] = (rank, h)
                if picks.get(forced or "score", (0,))[0] >= 4:
                    break
        return {"albums": [{"kind": k, "album": picks[k][1]} for k in ("score", "songs") if k in picks]}

    try:
        # Prázdný výsledek (výpadek Deezeru) necachovat na měsíc.
        found = (
            await cached_json(f"{cat.ns}:ost:{version}:{game.slug}", MONTH, fetch, is_empty=lambda v: not (v or {}).get("albums"))
        ).get("albums") or []
    except Exception:  # noqa: BLE001
        logger.exception("soundtrack %s", game.slug)
        return []
    out: list[dict[str, str]] = []
    with Session(engine) as session:
        for item in found:
            album = item.get("album") or {}
            artist = ingest_artist(session, album.get("artist") or {})
            release = ingest_album(session, album, artist) if artist else None
            if release is not None and all(o["id"] != release.id for o in out):
                out.append({"id": release.id, "kind": item.get("kind") or "score"})
        session.commit()
    return out


async def soundtrack(game: Game, cat: Catalog | None = None) -> str | None:
    """Hlavní album díla (score, jinak písně)."""
    albums = await soundtracks(game, cat)
    return albums[0]["id"] if albums else None


# ----------------------------------------------------------------------
# Stránka
# ----------------------------------------------------------------------


async def game_card(game: Game, cat: Catalog | None = None) -> dict[str, Any]:
    cat = cat or GAMES_CATALOG
    img, albums = await asyncio.gather(images(game), soundtracks(game, cat))
    album_id = albums[0]["id"] if albums else None
    hero = (img["hero"] or "").lower()
    if album_id and (
        not hero or img.get("lowres") or "logo" in hero or "title_card" in hero or hero.endswith((".svg", ".svg.png"))
    ):
        # Bez obrázku díla (Minecraft) nebo jen logo seriálu (Wikipedie):
        # obal soundtracku.
        from app.models import Release

        with Session(engine) as session:
            rel = session.get(Release, album_id)
            cover = (rel.images or [None])[0] if rel else None
        img = {"hero": cover, "cover": cover}
    series = cat.series.get(game.series or "") or ((game.series_title, "") if game.series_title else None)
    return {
        "slug": game.slug,
        "title": game.title,
        "year": game.year,
        "composers": list(game.composers),
        "series": game.series,
        "seriesTitle": series[0] if series else None,
        "hero": img["hero"],
        "cover": img["cover"],
        "albumId": album_id,
        "albums": albums,
    }


async def _cards(items: list[Game], cat: Catalog | None = None) -> list[dict[str, Any]]:
    sem = asyncio.Semaphore(6)

    async def one(g: Game) -> dict[str, Any]:
        async with sem:
            return await game_card(g, cat)

    return list(await asyncio.gather(*(one(g) for g in items)))


async def _album_tracks(album_id: str) -> list[dict[str, Any]]:
    from app.catalog.deezer import get_deezer_client
    from app.models import Release

    with Session(engine) as session:
        rel = session.get(Release, album_id)
        dz_id = rel.deezer_id if rel else None
    return (await get_deezer_client().album_tracks(str(dz_id)) or []) if dz_id else []


async def _mix(cat: Catalog, mix_id: str, cards: dict[str, dict[str, Any]]) -> str | None:
    """Mix z alb děl se štítkem (u bossů a témat jen skladby, jejichž název
    to říká), denně jinak zamíchaný; obal = mozaika obalů děl."""
    from app.home import generators as g
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistKind

    title, description, tags, words = cat.mixes[mix_id]
    rng = random.Random(f"{cat.ns}:{mix_id}:{utcnow().date().isoformat()}")
    picked: list[dict[str, Any]] = []
    covers: list[str] = []
    for item in cat.items:
        if not set(tags) & set(item.tags):
            continue
        card = cards.get(item.slug)
        if not card or not card.get("albumId"):
            continue
        tracks = await _album_tracks(card["albumId"])
        if words:
            tracks = [t for t in tracks if any(w in fold(t.get("title") or "").split() for w in words)] or tracks[:1]
        rng.shuffle(tracks)
        picked += tracks[:3 if not words else 4]
        if tracks and card.get("cover"):
            covers.append(card["cover"])
    rng.shuffle(picked)
    if not picked:
        return None
    ids = await asyncio.to_thread(g._ingest_tracks, picked[:60])
    return g._save_playlist(
        owner=GLOBAL_PLAYLIST_OWNER, source=f"{cat.ns}:mix:{mix_id}", title=title, description=description,
        kind=PlaylistKind.EDITORIAL, section=cat.ns, recording_ids=ids, cover_urls=rng.sample(covers, min(4, len(covers))),
        ttl=g.DAILY_TTL,
    )


async def page(cat: Catalog | None = None) -> dict[str, Any]:
    cat = cat or GAMES_CATALOG

    async def build() -> dict[str, Any]:
        cards_list = await _cards(cat.items, cat)
        cards = {c["slug"]: c for c in cards_list}
        rng = random.Random(f"{cat.ns}:hero:{utcnow().date().isoformat()}")
        heroes = [c for c in cards_list if c["hero"] and c["albumId"]]
        rng.shuffle(heroes)
        series = []
        for sid, (title, color) in cat.series.items():
            members = [cards[g.slug] for g in cat.items if g.series == sid]
            if len(members) < 2:
                continue
            latest = max(members, key=lambda c: c["year"])
            series.append({"id": sid, "title": title, "color": color, "image": latest["hero"] or latest["cover"], "count": len(members)})
        mixes = {}
        for mix_id in cat.mixes:
            try:
                mixes[mix_id] = await _mix(cat, mix_id, cards)
            except Exception:  # noqa: BLE001
                logger.exception("mix %s %s", cat.ns, mix_id)
        composers: list[str] = []
        for g in cat.items:
            for c in g.composers[:1]:
                if c not in composers and c != "Various Artists":
                    composers.append(c)
        from app import browse

        composer_ids = await browse._resolve_artists(composers, 24, set())

        def row(tag: str) -> list[dict[str, Any]]:
            rows = [cards[g.slug] for g in cat.items if tag in g.tags]
            return sorted(rows, key=lambda c: -c["year"]) if tag == "new" else rows

        return {
            "heroes": heroes[:10],
            "series": series,
            "seriesUnit": cat.series_unit,
            "mixIds": {k: v for k, v in mixes.items() if v},
            "composerIds": composer_ids,
            "rows": [
                *({"id": rid, "title": title, "games": row(tag)} for rid, title, tag in cat.rows),
                {"id": "all", "title": cat.all_title, "games": sorted(cards_list, key=lambda c: c["title"])},
            ],
        }

    key = "games:page:v12" if cat.ns == "games" else f"{cat.ns}:page:{cat.page_version}"
    return await cached_json(key, DAY, build, is_empty=lambda v: not v.get("rows"))


async def stations(game: Game) -> list[str]:
    """Rádia hry jako naše playlisty ("Radio Los Santos", obal hry): skladby
    z nejlepšího fanouškovského playlistu stanice na Deezeru, jehož název
    obsahuje stanici i hru. Měsíc v cache, playlist se obnovuje denně."""
    from app import browse
    from app.catalog.deezer import get_deezer_client
    from app.home import generators as g
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistKind

    if not game.stations:
        return []
    img = await images(game)
    dz = get_deezer_client()
    hints = [fold(h) for h in game.hints]

    async def one(station: str) -> str | None:
        async def fetch() -> dict[str, Any]:
            want = [w for w in _words(station) if w not in ("fm", "radio", "the")] or _words(station)
            for query in (f"{game.title} {station}", f"gta {station}"):
                for p in await browse.search_playlists(query, limit=12, min_tracks=8, max_tracks=200):
                    title = fold(p["title"])
                    words = set(_words(p["title"]))
                    if all(_covered(w, words) for w in want) and any(h in title for h in hints):
                        return {"deezerId": p["deezerId"]}
            return {}

        try:
            found = await cached_json(f"games:station:v1:{game.slug}:{station}", MONTH, fetch, is_empty=lambda v: not v)
        except Exception:  # noqa: BLE001
            return None
        if not found.get("deezerId"):
            return None
        tracks = await dz.playlist_tracks(found["deezerId"], 100) or []
        if not tracks:
            return None
        ids = await asyncio.to_thread(g._ingest_tracks, tracks)
        if not ids:
            return None
        return g._save_playlist(
            owner=GLOBAL_PLAYLIST_OWNER, source=f"games:station:{game.slug}:{fold(station)}", title=station,
            description=game.title, kind=PlaylistKind.EDITORIAL, section="games", recording_ids=ids,
            cover_urls=[img["cover"]] if img.get("cover") else [], ttl=g.DAILY_TTL,
        )

    async def cached(station: str) -> str | None:
        hit = await cached_json(f"games:station-pl:v1:{game.slug}:{station}", DAY, lambda: _wrap(one(station)), is_empty=lambda v: not v.get("id"))
        return hit.get("id")

    out = []
    for station in game.stations:
        try:
            pid = await cached(station)
        except Exception:  # noqa: BLE001
            logger.exception("rádio %s %s", game.slug, station)
            pid = None
        if pid:
            out.append(pid)
    return out


async def _wrap(coro) -> dict[str, Any]:
    return {"id": await coro}


async def game_page(slug: str, cat: Catalog | None = None) -> dict[str, Any] | None:
    cat = cat or GAMES_CATALOG
    game = next((g for g in cat.items if g.slug == slug), None)
    if game is None:
        return None
    card = await game_card(game, cat)
    others = [g for g in cat.items if game.series and g.series == game.series and g.slug != slug]
    return {
        **card,
        "seriesGames": await _cards(sorted(others, key=lambda g: g.year), cat),
        "stationIds": await stations(game),
        "stationsTitle": game.stations_title,
    }


async def series_page(series_id: str, cat: Catalog | None = None) -> dict[str, Any] | None:
    cat = cat or GAMES_CATALOG
    if series_id not in cat.series:
        return None
    title, color = cat.series[series_id]

    async def build() -> dict[str, Any]:
        items = sorted((g for g in cat.items if g.series == series_id), key=lambda g: g.year)
        cards = await _cards(items, cat)
        station_ids: list[str] = []
        for item in reversed(items):  # nejnovější díl napřed
            station_ids += await stations(item)
        return {
            "id": series_id, "title": title, "color": color, "games": cards, "unit": cat.series_unit,
            "playlistId": await _series_playlist(cat, series_id, cards, station_ids), "stationIds": station_ids,
        }

    key = f"games:series:v10:{series_id}" if cat.ns == "games" else f"{cat.ns}:series:{cat.page_version}:{series_id}"
    return await cached_json(key, DAY, build, is_empty=lambda v: not v.get("games"))


async def _series_playlist(
    cat: Catalog, series_id: str, cards: list[dict[str, Any]], station_ids: list[str] | None = None, title: str | None = None
) -> str | None:
    """Hudba ze všech dílů série jedním playlistem (chronologicky, celé
    soundtracky) -- jako stránka interpreta."""
    from app.home import generators as g
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistKind

    tracks: list[dict[str, Any]] = []
    for card in cards:
        for album in card.get("albums") or ([{"id": card["albumId"]}] if card.get("albumId") else []):
            tracks += await _album_tracks(album["id"])
    ids = await asyncio.to_thread(g._ingest_tracks, tracks[:400]) if tracks else []
    if station_ids:
        # GTA: hudba série = rádia všech dílů (soundtrack jako album nevyšel).
        from app.models import PlaylistItem
        from sqlmodel import select

        with Session(engine) as session:
            for pid in station_ids:
                ids += [
                    i.recording_id
                    for i in session.exec(select(PlaylistItem).where(PlaylistItem.playlist_id == pid).order_by(PlaylistItem.position)).all()
                ]
        ids = list(dict.fromkeys(ids))[:800]
    if not ids:
        return None
    title = title or cat.series[series_id][0]
    return g._save_playlist(
        owner=GLOBAL_PLAYLIST_OWNER, source=f"{cat.ns}:series:{series_id}", title=f"{title} · celá série",
        description="Soundtracky všech dílů série", kind=PlaylistKind.EDITORIAL, section=cat.ns,
        recording_ids=ids, cover_urls=[c["cover"] for c in cards if c.get("cover")][-4:], ttl=g.DAILY_TTL,
    )


GAMES_CATALOG = Catalog(
    ns="games",
    items=GAMES,
    series=SERIES,
    mixes=GAME_MIXES,
    labels=_LABELS,
    sequel=frozenset(_SEQUEL),
    rows=(
        ("new", "Nové soundtracky", "new"),
        ("indie", "Indie klenoty", "indie"),
        ("retro", "Legendy 8/16-bit", "retro"),
        ("czech", "Česká stopa", "czech"),
    ),
    all_title="Všechny hry",
    series_unit="her",
)


# ----------------------------------------------------------------------
# Díla a série z Wikidat (app/works.py) -- "skoro cokoliv"
# ----------------------------------------------------------------------


def catalog_for(kind: str) -> Catalog:
    from app.movies import MOVIES_CATALOG

    return GAMES_CATALOG if kind == "game" else MOVIES_CATALOG


def base_for(kind: str) -> str:
    return "games" if kind == "game" else "movies"


async def work_page(qid: str) -> dict[str, Any] | None:
    from app import works

    found = await works.get(qid)
    if found is None:
        return None
    game, kind = found
    cat = catalog_for(kind)
    card = await game_card(game, cat)
    others: list[dict[str, Any]] = []
    if game.series and works.is_qid(game.series):
        _title, members = await works.series_members(game.series)
        others = await _cards([g for g, _k in members if g.slug != qid][:16], cat)
    return {**card, "kind": kind, "base": base_for(kind), "seriesGames": others, "stationIds": [], "stationsTitle": "Rádia"}


async def work_series_page(qid: str) -> dict[str, Any] | None:
    from app import works

    async def build() -> dict[str, Any]:
        title, members = await works.series_members(qid)
        if not members:
            return {}
        kinds = [k for _g, k in members]
        kind = max(set(kinds), key=kinds.count)
        cat = catalog_for(kind)
        cards = await _cards([g for g, _k in members][:40], cat)
        return {
            "id": qid, "title": title, "color": "", "games": cards, "unit": "her" if kind == "game" else "dílů",
            "base": base_for(kind), "stationIds": [],
            "playlistId": await _series_playlist(cat, qid, cards, title=title),
        }

    out = await cached_json(f"works:series:v2:{qid}", DAY, build, is_empty=lambda v: not v.get("games"))
    return out or None


async def work_search(query: str, limit: int = 8) -> list[dict[str, Any]]:
    """Hledání děl (Hledat): plakát, rok a kam vést -- franšíza (jako
    interpret), jinak rovnou album soundtracku. Bez obojího se neukáže."""
    from app import works

    found = await works.search(query, limit)

    async def card(item: tuple[Game, str]) -> dict[str, Any] | None:
        game, kind = item
        cat = catalog_for(kind)
        img, albums = await asyncio.gather(images(game), soundtracks(game, cat))
        franchise = game.series if game.series else None
        if not albums and not franchise:
            return None
        cover = img["cover"]
        if albums and (not cover or img.get("lowres")):
            from app.models import Release

            with Session(engine) as session:
                rel = session.get(Release, albums[0]["id"])
                cover = (rel.images or [cover])[0] if rel else cover
        return {
            "slug": game.slug, "title": game.title, "year": game.year, "kind": kind,
            "cover": cover, "albumId": albums[0]["id"] if albums else None, "franchise": franchise,
            "franchiseTitle": game.series_title,
        }

    cards = await works.gather_limited([card(i) for i in found], 4)
    return [c for c in cards if c]
