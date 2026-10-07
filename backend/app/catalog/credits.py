"""Obsazení alba ("kdo na čem hrál") z MusicBrainz -- vztahy interpretů
k nahrávkám (nástroj, zpěv, produkce, zvuk...) a k dílům (skladatel,
textař). MB je drží hlavně u jednotlivých nahrávek, ne u alba, proto se
čte celá kanonická edice s `recording-level-rels` a role se sečtou přes
skladby ("baskytara · 12 skladeb").

Lidé se třídí do skupin: hudebníci, autoři, produkce. Nástroje a role
česky (běžné; neznámé zůstanou, jak je MB pojmenuje).
"""

from __future__ import annotations

from collections import defaultdict
from typing import Any

_INSTRUMENTS = {
    "guitar": "kytara", "acoustic guitar": "akustická kytara", "electric guitar": "elektrická kytara",
    "classical guitar": "klasická kytara", "slide guitar": "slide kytara", "steel guitar": "steel kytara",
    "pedal steel guitar": "pedal steel", "lap steel guitar": "lap steel", "resonator guitar": "dobro",
    "dobro": "dobro", "bass guitar": "baskytara", "bass": "basa", "double bass": "kontrabas",
    "electric bass guitar": "baskytara", "acoustic bass guitar": "akustická baskytara",
    "drums (drum set)": "bicí", "drums": "bicí", "drum machine": "bicí automat", "percussion": "perkuse",
    "piano": "klavír", "keyboard": "klávesy", "synthesizer": "syntezátor", "organ": "varhany",
    "hammond organ": "hammondovy varhany", "electric piano": "elektrické piano", "rhodes piano": "Rhodes",
    "harpsichord": "cembalo", "accordion": "akordeon", "harmonica": "foukací harmonika",
    "violin": "housle", "fiddle": "housle", "viola": "viola", "cello": "violoncello", "strings": "smyčce",
    "mandolin": "mandolína", "banjo": "banjo", "five-string banjo": "pětistrunné banjo", "ukulele": "ukulele",
    "harp": "harfa", "flute": "flétna", "recorder": "zobcová flétna", "piccolo": "pikola", "clarinet": "klarinet",
    "bass clarinet": "basklarinet", "oboe": "hoboj", "bassoon": "fagot", "saxophone": "saxofon",
    "alto saxophone": "altsaxofon", "tenor saxophone": "tenorsaxofon", "baritone saxophone": "barytonsaxofon",
    "soprano saxophone": "sopránsaxofon", "trumpet": "trubka", "flugelhorn": "křídlovka", "trombone": "trombon",
    "french horn": "lesní roh", "horn": "lesní roh", "tuba": "tuba", "brass": "žestě", "woodwind": "dřevo",
    "glockenspiel": "zvonkohra", "vibraphone": "vibrafon", "marimba": "marimba", "xylophone": "xylofon",
    "tambourine": "tamburína", "congas": "konga", "bongos": "bonga", "timpani": "tympány", "cymbal": "činely",
    "shaker": "šejkr", "handclaps": "tleskání", "sitar": "sitár", "theremin": "theremin",
    "melodica": "melodika", "kalimba": "kalimba", "bouzouki": "buzuki", "dulcimer": "cimbál",
    "hammered dulcimer": "cimbál", "autoharp": "autoharfa", "jaw harp": "brumle", "bagpipes": "dudy",
    "tin whistle": "píšťalka", "whistle": "pískání", "mellotron": "mellotron", "sampler": "sampler",
    "guitar synthesizer": "kytarový syntezátor", "twelve-string guitar": "dvanáctistrunná kytara",
    "bowed bass": "kontrabas (smyčcem)", "sousaphone": "suzafon", "cornet": "kornet", "celesta": "celesta",
    "bass synthesizer": "basový syntezátor", "keyboard bass": "klávesová basa", "fretless bass guitar":
    "bezpražcová baskytara", "fretless bass": "bezpražcová basa", "baritone guitar": "barytonová kytara",
    "tenor guitar": "tenorová kytara", "upright bass": "kontrabas", "electric upright bass": "elektrický kontrabas",
    "contrabass": "kontrabas", "electric organ": "elektrické varhany", "pipe organ": "píšťalové varhany",
    "pump organ": "harmonium", "harmonium": "harmonium", "grand piano": "koncertní křídlo",
    "upright piano": "pianino", "toy piano": "dětské piano", "prepared piano": "preparovaný klavír",
    "clavinet": "clavinet", "wurlitzer electric piano": "elektrické piano Wurlitzer", "synth": "syntezátor",
    "modular synthesizer": "modulární syntezátor", "analog synthesizer": "analogový syntezátor",
    "string synthesizer": "smyčcový syntezátor", "drum programming": "programování bicích",
    "electronic drum set": "elektronické bicí", "snare drum": "malý buben", "bass drum": "velký buben",
    "hi-hat": "hi-hat", "cowbell": "kravský zvonec", "triangle": "triangl", "claves": "claves",
    "cabasa": "cabasa", "güiro": "guiro", "steelpan": "steel drum", "tabla": "tabla", "djembe": "djembe",
    "cajón": "cajón", "bells": "zvony", "tubular bells": "trubicové zvony", "chimes": "zvonkohra",
    "wind chimes": "zvonkohra", "gong": "gong", "electric violin": "elektrické housle",
    "electric cello": "elektrické violoncello", "electric mandolin": "elektrická mandolína",
    "mandola": "mandola", "lute": "loutna", "zither": "citera", "concertina": "koncertina",
    "bandoneon": "bandoneon", "button accordion": "knoflíkový akordeon", "piano accordion": "klávesový akordeon",
    "pan flute": "panova flétna", "alto flute": "altová flétna", "bass flute": "basová flétna",
    "english horn": "anglický roh", "contrabassoon": "kontrafagot", "bass trombone": "basový trombon",
    "valve trombone": "ventilový trombon", "euphonium": "eufonium", "piccolo trumpet": "pikolová trubka",
    "bass saxophone": "bassaxofon", "wind instrument": "dechový nástroj", "keyboard instrument": "klávesy",
    "string instruments": "smyčce", "turntables": "gramofony", "electronic instruments": "elektronika",
    "fender rhodes": "Rhodes", "rhodes": "Rhodes", "talk box": "talkbox", "vocoder": "vokodér", "loops": "smyčky", "effects": "efekty",
    "tape": "magnetofon", "samples": "samply", "field recordings": "terénní nahrávky",
}

# Přívlastek před známým nástrojem ("bass synthesizer" -> basový syntezátor).
_ADJECTIVES = {
    "bass": "basový", "electric": "elektrický", "acoustic": "akustický", "analog": "analogový",
    "digital": "digitální", "modular": "modulární", "string": "smyčcový", "fretless": "bezpražcový",
    "electronic": "elektronický", "baritone": "barytonový", "tenor": "tenorový", "alto": "altový",
    "soprano": "sopránový", "prepared": "preparovaný",
}


def _instrument(name: str) -> str:
    """Česky: přesná shoda, jinak známý konec názvu a zbytek jako přívlastek
    nebo v závorce ("Moog synthesizer" -> "syntezátor (Moog)"). Úplně
    neznámý zůstane, jak ho MusicBrainz pojmenuje (audit 7. 10.: "bass
    synthesizer" anglicky v Obsazení)."""
    key = name.lower().strip()
    if key in _INSTRUMENTS:
        return _INSTRUMENTS[key]
    words = key.split()
    for i in range(1, len(words)):
        tail = " ".join(words[i:])
        if tail not in _INSTRUMENTS:
            continue
        cz = _INSTRUMENTS[tail]
        head = name.split()[:i]
        if all(w.lower() in _ADJECTIVES for w in head):
            noun = cz.split()[-1]
            return " ".join(_adjective(_ADJECTIVES[w.lower()], noun) for w in head) + " " + cz
        return f"{cz} ({' '.join(head)})"
    return name


def _adjective(masculine: str, noun: str) -> str:
    """Rod přívlastku podle podstatného jména (kytara -> basová, piano -> basové)."""
    if not masculine.endswith("ý"):
        return masculine  # digitální, elektrický je mužský -- měkká přídavná jména se nemění
    if noun.endswith("a"):
        return masculine[:-1] + "á"
    if noun.endswith(("o", "e", "í")):
        return masculine[:-1] + "é"
    return masculine

_VOCALS = {
    "lead vocals": "zpěv", "background vocals": "doprovodný zpěv", "choir vocals": "sbor",
    "spoken vocals": "mluvené slovo", "harmony vocals": "vokály", "other vocals": "zpěv",
    "baritone vocals": "baryton", "tenor vocals": "tenor", "soprano vocals": "soprán", "alto vocals": "alt",
    "bass vocals": "bas", "mezzo-soprano vocals": "mezzosoprán", "rapping": "rap",
}

# Typ vztahu -> (skupina, popisek). Nástroj a zpěv se popíšou atributem.
_ROLES = {
    "instrument": ("musicians", None),
    "vocal": ("musicians", None),
    "performer": ("musicians", "hraje"),
    "performing orchestra": ("musicians", "orchestr"),
    "conductor": ("musicians", "dirigent"),
    "chorus master": ("musicians", "sbormistr"),
    "concertmaster": ("musicians", "koncertní mistr"),
    "composer": ("writers", "hudba"),
    "lyricist": ("writers", "text"),
    "writer": ("writers", "autor"),
    "librettist": ("writers", "libreto"),
    "arranger": ("writers", "aranžmá"),
    "instrument arranger": ("writers", "aranžmá"),
    "vocal arranger": ("writers", "vokální aranžmá"),
    "orchestrator": ("writers", "orchestrace"),
    "producer": ("production", "produkce"),
    "co-producer": ("production", "koprodukce"),
    "executive producer": ("production", "výkonný producent"),
    "mix": ("production", "mix"),
    "engineer": ("production", "zvuk"),
    "audio": ("production", "zvuk"),
    "sound": ("production", "zvuk"),
    "recording": ("production", "nahrávání"),
    "mastering": ("production", "mastering"),
    "programming": ("production", "programování"),
    "remixer": ("production", "remix"),
}

# Atributy, které z role nedělají jiný nástroj -- jen poznámka.
_QUALIFIERS = {"additional", "guest", "solo", "assistant", "co", "executive", "associate", "translated"}


def _label(rel: dict[str, Any]) -> tuple[str, str] | None:
    """(skupina, popisek) pro jeden vztah, nebo None (nezajímavý vztah)."""
    kind = rel.get("type") or ""
    if kind not in _ROLES:
        return None
    group, label = _ROLES[kind]
    attrs = [a for a in rel.get("attributes") or [] if a not in _QUALIFIERS]
    if "assistant" in (rel.get("attributes") or []):
        return None  # asistenti zvuku -- šum v seznamu
    if kind == "instrument":
        label = ", ".join(_instrument(a) for a in attrs) or "nástroje"
    elif kind == "vocal":
        label = ", ".join(_VOCALS.get(a.lower(), a) for a in attrs) or "zpěv"
    if "guest" in (rel.get("attributes") or []):
        label += " (host)"
    return group, label or kind


def album_credits(release: dict[str, Any]) -> dict[str, list[dict[str, Any]]]:
    """MB release s `artist-rels+recordings+recording-level-rels+work-rels+
    work-level-rels` -> {"musicians": [...], "writers": [...],
    "production": [...], "tracks": počet skladeb}. Každý člověk:
    {name, mbid, roles: [{label, tracks}]}, nejvíc skladeb první."""
    tracks = [t for m in release.get("media") or [] for t in m.get("tracks") or []]
    total = len(tracks)
    # (skupina, mbid/jméno) -> {"name", "mbid", roles: {label: set(track ids)}}
    people: dict[tuple[str, str], dict[str, Any]] = {}

    def add(rel: dict[str, Any], track_id: str | None) -> None:
        artist = rel.get("artist") or {}
        if rel.get("target-type") != "artist" or not artist.get("name"):
            return
        labeled = _label(rel)
        if labeled is None:
            return
        group, label = labeled
        key = (group, artist.get("id") or artist["name"])
        person = people.setdefault(key, {"name": artist["name"], "mbid": artist.get("id"), "roles": defaultdict(set)})
        # Vztah k celému albu = všechny skladby.
        person["roles"][label] |= {t.get("id") for t in tracks} if track_id is None else {track_id}

    for rel in release.get("relations") or []:
        add(rel, None)
    for t in tracks:
        rec = t.get("recording") or {}
        for rel in rec.get("relations") or []:
            add(rel, t.get("id"))
            # Nahrávka -> dílo -> skladatel/textař.
            if rel.get("target-type") == "work":
                for wrel in (rel.get("work") or {}).get("relations") or []:
                    add(wrel, t.get("id"))

    out: dict[str, Any] = {"musicians": [], "writers": [], "production": [], "tracks": total}
    for (group, _key), person in people.items():
        roles = sorted(
            ({"label": label, "tracks": len(ids)} for label, ids in person["roles"].items()),
            key=lambda r: -r["tracks"],
        )
        out[group].append({"name": person["name"], "mbid": person["mbid"], "roles": roles})
    for group in ("musicians", "writers", "production"):
        out[group].sort(key=lambda p: (-max((r["tracks"] for r in p["roles"]), default=0), p["name"]))
    return out
