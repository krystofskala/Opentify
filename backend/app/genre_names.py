"""Názvy žánrů a stylů pro zobrazení podle jazyka.

Štítky žánrů přicházejí anglicky (MusicBrainz, Last.fm, Deezer). Appka je
česky, tak se v popisech mixů a na obalech ukazují české názvy. Slovník je po
jazycích, aby šla později i anglická verze appky: jazyk bez slovníku (en)
vrací původní štítek. Neznámý štítek zůstává, jak je -- hodně žánrů se česky
říká stejně (rock, folk, jazz, reggae...).
"""

_CS = {
    # scény / země
    "czech": "česká scéna",
    "czech folk": "český folk",
    "czech rock": "český rock",
    "czech hip hop": "český hip hop",
    "slovak": "slovenská scéna",
    "french": "francouzská scéna",
    "german": "německá scéna",
    "polish": "polská scéna",
    "british": "britská scéna",
    "irish": "irská scéna",
    "scandinavian": "skandinávská scéna",
    "japanese": "japonská scéna",
    "latin": "latinskoamerická hudba",
    "celtic": "keltská hudba",
    "irish folk": "irský folk",
    "british folk rock": "britský folk rock",
    "chanson": "šanson",
    # obecné
    "electronic": "elektronika",
    "electronica": "elektronika",
    "classical": "klasika",
    "western classical": "klasika",
    "modern classical": "moderní klasika",
    "chinese classical": "čínská klasika",
    "indian classical": "indická klasika",
    "instrumental": "instrumentální",
    "experimental": "experimentální",
    "acoustic": "akustická",
    "christmas music": "vánoční hudba",
    "christmas": "vánoční hudba",
    "musical": "muzikál",
    "soundtrack": "filmová hudba",
    "children's music": "pro děti",
    "spoken word": "mluvené slovo",
    "singer-songwriter": "písničkáři",
    "ballad": "balady",
    "easy listening": "pohodová hudba",
    "new age": "new age",
    "chillout": "chillout",
    "oldies": "staré pecky",
    "world": "world music",
    "avant-garde": "avantgarda",
    "non-music": "nehudební",
    "interview": "rozhovory",
    # rock
    "alternative": "alternativa",
    "alternative rock": "alternativní rock",
    "classic rock": "klasický rock",
    "psychedelic rock": "psychedelický rock",
    "psychedelic": "psychedelie",
    "psychedelic pop": "psychedelický pop",
    "neo-psychedelia": "neopsychedelie",
    "progressive rock": "progresivní rock",
    "progressive": "progresivní",
    "experimental rock": "experimentální rock",
    "acoustic rock": "akustický rock",
    "southern rock": "jižanský rock",
    "soft rock": "soft rock",
    "garage rock": "garážový rock",
    "gothic rock": "gotický rock",
    "christian rock": "křesťanský rock",
    "instrumental rock": "instrumentální rock",
    "electronic rock": "elektronický rock",
    "piano rock": "klavírní rock",
    "mainstream rock": "hlavní proud rocku",
    "arena rock": "stadionový rock",
    "roots rock": "kořenový rock",
    "heartland rock": "heartland rock",
    "art rock": "art rock",
    "noise rock": "noise rock",
    "post-rock": "post-rock",
    # pop
    "alternative pop": "alternativní pop",
    "ambient pop": "ambientní pop",
    "traditional pop": "tradiční pop",
    "baroque pop": "barokní pop",
    "chamber pop": "komorní pop",
    "dream pop": "snový pop",
    "bedroom pop": "bedroom pop",
    # folk, country
    "contemporary folk": "současný folk",
    "chamber folk": "komorní folk",
    "avant-folk": "avantgardní folk",
    "alternative country": "alternativní country",
    "contemporary country": "současné country",
    "progressive bluegrass": "progresivní bluegrass",
    # jazz, blues, soul
    "contemporary jazz": "současný jazz",
    "vocal jazz": "vokální jazz",
    "smooth jazz": "smooth jazz",
    "gypsy jazz": "cikánský jazz",
    "avant-garde jazz": "avantgardní jazz",
    "piano blues": "klavírní blues",
    "country blues": "country blues",
    "desert blues": "pouštní blues",
    "contemporary r&b": "současné r&b",
    "alternative r&b": "alternativní r&b",
    "contemporary gospel": "současný gospel",
    # hip hop, elektronika
    "alternative hip hop": "alternativní hip hop",
    "abstract hip hop": "abstraktní hip hop",
    "conscious hip hop": "uvědomělý hip hop",
    "alternative dance": "alternativní taneční",
    "dance": "taneční",
    "club": "klubová hudba",
    "alternative metal": "alternativní metal",
    "alternative punk": "alternativní punk",
    "heavy metal": "heavy metal",
}

NAMES: dict[str, dict[str, str]] = {"cs": _CS}


def genre_name(tag: str, lang: str = "cs") -> str:
    """Zobrazovaný název žánru `tag` v jazyce `lang`; neznámý zůstává."""
    return NAMES.get(lang, {}).get(tag.strip().lower(), tag)
