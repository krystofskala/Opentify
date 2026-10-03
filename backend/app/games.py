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

import asyncio
import logging
import random
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
_UA = {"User-Agent": "Opentify/1.0 (claudstopher@gmail.com)"}


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
        return {"url": ((data.get("originalimage") or data.get("thumbnail") or {}).get("source"))}

    try:
        return (await cached_json(f"games:wiki:{title}", MONTH, fetch, is_empty=lambda v: not v.get("url"))).get("url")
    except Exception:  # noqa: BLE001
        return None


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
    if hero is None:
        wiki = await _wiki_image(game.wiki or game.title)
        hero = cover = wiki
    return {"hero": hero, "cover": cover}


# ----------------------------------------------------------------------
# Soundtrack
# ----------------------------------------------------------------------

_NOT_OST = ("piano", "lofi", "lo-fi", "cover", "covers", "tribute", "remix", "remixes", "acoustic", "guitar", "8-bit version",
            "orchestral covers", "karaoke", "relax", "sleep", "chill", "trailer", "best soundtracks", "inspired by")
# Jiný díl / jiné dílo: číslo, římská číslice, pokračování, film.
_SEQUEL = {
    "ii", "iii", "iv", "v", "vi", "vii", "viii", "ix", "x", "xi", "xii", "xiii", "xiv", "xv", "xvi", "2", "3", "4", "5", "6",
    "part", "chapter", "movie", "film", "nightreign", "remake", "rebirth", "reborn", "origins", "dlc", "expansion", "dungeons",
    "odst", "reach", "season", "hbo", "tv", "series", "anime",
}
# Oficiální vydavatelé herní hudby (soundtrack nevydaný pod jménem skladatele).
_LABELS = (
    "square enix music", "nintendo", "atlus game music", "fromsoftware sound team", "re-logic", "sega", "capcom",
    "konami", "bethesda", "xbox music", "halo", "aperture science", "bandai namco", "supergiant games",
    "cd projekt red", "rockstar games", "warhorse studios", "2k", "mojang", "sony interactive",
)


def _words(text: str) -> list[str]:
    return [w for w in tokens(text.replace(":", " ").replace("-", " "))]


async def soundtrack(game: Game) -> str | None:
    """Id našeho alba se soundtrackem hry. Jen celé album od skladatele
    hry nebo oficiálního vydavatele, se stejným dílem (ne VII místo X, ne
    Part II, ne film, ne covery/piano/lo-fi). Radši nic než cizí album."""
    from app.catalog.deezer import get_deezer_client
    from app.catalog.deezer_ingest import ingest_album, ingest_artist

    async def fetch() -> dict[str, Any]:
        dz = get_deezer_client()
        name = game.album or game.title
        want = [w for w in _words(name) if w not in ("the", "of", "a", "and")]
        title_words = set(_words(game.title)) | set(_words(name))
        composers = {fold(c) for c in game.composers}
        best: tuple[int, dict[str, Any]] | None = None
        for q in (f"{name} soundtrack", f"{game.composers[0]} {name}", name):
            hits = await dz._cached_data(f"dz:search_album_q:{q}", MONTH, "/search/album", {"q": q, "limit": 25}) or []
            for h in hits:
                title = h.get("title") or ""
                artist = fold((h.get("artist") or {}).get("name") or "")
                words = _words(title)
                if not all(_covered(w, set(words)) for w in want):
                    continue
                if {w for w in words if w in _SEQUEL} - title_words:
                    continue
                low = fold(title)
                if any(bad in low for bad in _NOT_OST):
                    continue
                if int(h.get("nb_tracks") or 0) and int(h.get("nb_tracks") or 0) < 5:
                    continue
                by_composer = any(c in artist or (artist and artist in c) for c in composers)
                by_label = any(label in artist for label in _LABELS)
                if not (by_composer or by_label):
                    continue
                official = any(w in low for w in ("original", "soundtrack", "ost", "score", "music from"))
                score = (3 if by_composer else 1) + (1 if official else 0)
                if best is None or score > best[0]:
                    best = (score, h)
            if best and best[0] >= 4:
                break
        return {"album": best[1] if best else None}

    try:
        found = (await cached_json(f"games:ost:v3:{game.slug}", MONTH, fetch)).get("album")
    except Exception:  # noqa: BLE001
        logger.exception("soundtrack %s", game.slug)
        return None
    if not found:
        return None
    with Session(engine) as session:
        artist = ingest_artist(session, found.get("artist") or {})
        release = ingest_album(session, found, artist) if artist else None
        session.commit()
        return release.id if release else None


# ----------------------------------------------------------------------
# Stránka
# ----------------------------------------------------------------------


async def game_card(game: Game) -> dict[str, Any]:
    img, album_id = await asyncio.gather(images(game), soundtrack(game))
    if not img["hero"] and album_id:
        # Bez obrázku hry (Minecraft) aspoň obal soundtracku.
        from app.models import Release

        with Session(engine) as session:
            rel = session.get(Release, album_id)
            cover = (rel.images or [None])[0] if rel else None
        img = {"hero": cover, "cover": cover}
    series = SERIES.get(game.series or "")
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
    }


async def _cards(games: list[Game]) -> list[dict[str, Any]]:
    sem = asyncio.Semaphore(6)

    async def one(g: Game) -> dict[str, Any]:
        async with sem:
            return await game_card(g)

    return list(await asyncio.gather(*(one(g) for g in games)))


async def _mix(mix_id: str, cards: dict[str, dict[str, Any]]) -> str | None:
    """Herní mix z alb her se štítkem (u bossů a témat jen skladby, jejichž
    název to říká), denně jinak zamíchaný."""
    from app.catalog.deezer import get_deezer_client
    from app.home import generators as g
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistKind

    title, description, tags, words = GAME_MIXES[mix_id]
    dz = get_deezer_client()
    rng = random.Random(f"games:{mix_id}:{utcnow().date().isoformat()}")
    picked: list[dict[str, Any]] = []
    covers: list[str] = []
    for game in GAMES:
        if not set(tags) & set(game.tags):
            continue
        card = cards.get(game.slug)
        if not card or not card.get("albumId"):
            continue
        with Session(engine) as session:
            from app.models import Release

            rel = session.get(Release, card["albumId"])
            dz_id = rel.deezer_id if rel else None
        tracks = (await dz.album_tracks(str(dz_id)) or []) if dz_id else []
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
        owner=GLOBAL_PLAYLIST_OWNER, source=f"games:mix:{mix_id}", title=title, description=description,
        kind=PlaylistKind.EDITORIAL, section="games", recording_ids=ids, cover_urls=rng.sample(covers, min(4, len(covers))),
        ttl=g.DAILY_TTL,
    )


async def page() -> dict[str, Any]:
    async def build() -> dict[str, Any]:
        cards_list = await _cards(GAMES)
        cards = {c["slug"]: c for c in cards_list}
        rng = random.Random(f"games:hero:{utcnow().date().isoformat()}")
        heroes = [c for c in cards_list if c["hero"] and c["albumId"]]
        rng.shuffle(heroes)
        series = []
        for sid, (title, color) in SERIES.items():
            members = [cards[g.slug] for g in GAMES if g.series == sid]
            if len(members) < 2:
                continue
            latest = max(members, key=lambda c: c["year"])
            series.append({"id": sid, "title": title, "color": color, "image": latest["hero"] or latest["cover"], "count": len(members)})
        mixes = {}
        for mix_id in GAME_MIXES:
            try:
                mixes[mix_id] = await _mix(mix_id, cards)
            except Exception:  # noqa: BLE001
                logger.exception("herní mix %s", mix_id)
        composers: list[str] = []
        for g in GAMES:
            for c in g.composers[:1]:
                if c not in composers:
                    composers.append(c)
        from app import browse

        composer_ids = await browse._resolve_artists(composers, 24, set())

        def row(tag: str) -> list[dict[str, Any]]:
            return [cards[g.slug] for g in GAMES if tag in g.tags]

        return {
            "heroes": heroes[:6],
            "series": series,
            "mixIds": {k: v for k, v in mixes.items() if v},
            "composerIds": composer_ids,
            "rows": [
                {"id": "new", "title": "Nové soundtracky", "games": sorted(row("new"), key=lambda c: -c["year"])},
                {"id": "indie", "title": "Indie klenoty", "games": row("indie")},
                {"id": "retro", "title": "Legendy 8/16-bit", "games": row("retro")},
                {"id": "czech", "title": "Česká stopa", "games": row("czech")},
                {"id": "all", "title": "Všechny hry", "games": sorted(cards_list, key=lambda c: c["title"])},
            ],
        }

    return await cached_json("games:page:v5", DAY, build, is_empty=lambda v: not v.get("rows"))


async def game_page(slug: str) -> dict[str, Any] | None:
    game = get(slug)
    if game is None:
        return None
    card = await game_card(game)
    others = [g for g in GAMES if game.series and g.series == game.series and g.slug != slug]
    return {**card, "seriesGames": await _cards(sorted(others, key=lambda g: g.year))}


async def series_page(series_id: str) -> dict[str, Any] | None:
    if series_id not in SERIES:
        return None
    title, color = SERIES[series_id]

    async def build() -> dict[str, Any]:
        games = sorted((g for g in GAMES if g.series == series_id), key=lambda g: g.year)
        cards = await _cards(games)
        return {"id": series_id, "title": title, "color": color, "games": cards, "playlistId": await _series_playlist(series_id, cards)}

    return await cached_json(f"games:series:v3:{series_id}", DAY, build, is_empty=lambda v: not v.get("games"))


async def _series_playlist(series_id: str, cards: list[dict[str, Any]]) -> str | None:
    """Hudba ze všech her série jedním playlistem (chronologicky, celé
    soundtracky) -- jako stránka interpreta, jen pro hru."""
    from app.catalog.deezer import get_deezer_client
    from app.home import generators as g
    from app.models import GLOBAL_PLAYLIST_OWNER, PlaylistKind, Release

    dz = get_deezer_client()
    tracks: list[dict[str, Any]] = []
    for card in cards:
        if not card.get("albumId"):
            continue
        with Session(engine) as session:
            rel = session.get(Release, card["albumId"])
            dz_id = rel.deezer_id if rel else None
        tracks += (await dz.album_tracks(str(dz_id)) or []) if dz_id else []
    if not tracks:
        return None
    ids = await asyncio.to_thread(g._ingest_tracks, tracks[:400])
    title = SERIES[series_id][0]
    return g._save_playlist(
        owner=GLOBAL_PLAYLIST_OWNER, source=f"games:series:{series_id}", title=f"{title} · celá série",
        description="Soundtracky všech her série", kind=PlaylistKind.EDITORIAL, section="games",
        recording_ids=ids, cover_urls=[c["cover"] for c in cards if c.get("cover")][-4:], ttl=g.DAILY_TTL,
    )
