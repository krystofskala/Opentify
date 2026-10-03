"""Je tenhle soubor / video PŘESNĚ ta skladba? Společné jádro pro Soulseek,
YouTube, SoundCloud, složky alb i kontrolní nástroje.

Pravidlo majitele: radši "nemáme" než jiná verze nebo jiná píseň. Proto
whitelist, ne blacklist -- kromě názvu skladby, interpreta, alba, čísla
stopy a známého "šumu" (Official Video, Remastered 2011, [FLAC], feat. X)
nesmí v názvu kandidáta být NIC navíc. Dřív stačilo, aby slova názvu byla
kdekoli v cestě, a tak (živě, viz audit 2026-10-03):

- "Harvest Moon"  <- "Neil Young - Harvest Moon - 08 - Old King.flac"
- "Believe"       <- "0104 - Reason to Believe.flac"
- "Cherry"        <- "Cherry Blossom.flac", "Love" <- "Love Song.flac"
- "Radio" (Future)<- "SPARKLEWOLF RADIO - in the near future!.flac"
- "22"            <- "22 (Taylor's Version)" by prošlo jako originál
- japonské/čínské názvy neměly po normalizaci žádná slova -> prošlo cokoli.

`match_label()` vrací None (sedí) nebo důvod (česky, do logu).
"""

from __future__ import annotations

import html
import re
import unicodedata
from difflib import SequenceMatcher

# Spojky a zbytky po apostrofech, co se v názvech souborů píšou různě.
_STOP = {"the", "a", "an", "and", "n", "und", "et", "y"}

# Slova, která verzi nemění (v závorce i mimo ni).
NOISE = {
    "version", "remaster", "remastered", "remastering", "mix", "edit", "original", "radio", "single", "album",
    "mono", "stereo", "deluxe", "bonus", "track", "explicit", "clean", "official", "audio", "video", "music",
    "lyric", "lyrics", "letra", "hd", "hq", "4k", "1080p", "720p", "visualizer", "visualiser", "digital",
    "edition", "anniversary", "expanded", "soundtrack", "motion", "picture", "ost", "flac", "mp3", "kbps",
    "320", "320kbps", "16bit", "24bit", "bit", "khz", "cd", "web", "vinyl", "lp", "ep", "topic", "vevo",
    "from", "of", "in", "by", "feat", "ft", "featuring", "with", "prod", "stream", "streaming", "premiere",
    "high", "quality", "best", "oficialni", "klip", "videoklip", "lyrics", "subtitulado", "traducida",
}

# Jiná verze / jiná nahrávka / nehudební video -- nesmí být v kandidátovi,
# pokud o ni skladba (název, album) sama neříká.
MARKERS = frozenset({
    "live", "acoustic", "cover", "covers", "remix", "rmx", "karaoke", "instrumental", "piano", "ukulele",
    "reaction", "sped", "slowed", "reverb", "nightcore", "concert", "demo", "demos", "unplugged", "orchestral",
    "lullaby", "8bit", "8d", "tribute", "mashup", "medley", "megamix", "bootleg", "interview", "podcast",
    "talks", "talking", "explains", "explained", "documentary", "trailer", "teaser", "snippet", "tutorial",
    "lesson", "chords", "tabs", "unboxing", "vlog", "react", "reacts", "breakdown", "analysis", "review",
    "speech", "rozhovor", "session", "sessions", "rehearsal", "outtake", "outtakes", "alternate", "take",
    "takes", "bbc", "commentary", "intro", "outro", "extended", "hour", "hours", "loop", "acapella",
    "cappella", "stems", "isolated", "drumless", "backing", "boosted", "lofi", "parody", "fanmade",
    "livestream", "kexp", "audiotree", "desk", "rework", "remake", "dub", "vip", "naživo", "nazivo",
    "koncert", "rehearsals", "soundcheck", "cifra",
})

# Ve složce (kontextu) jen jednoznačné značky -- "Sessions", "Take", "Intro"
# bývají i v názvech studiových alb.
CONTEXT_MARKERS = frozenset({
    "live", "unplugged", "concert", "bootleg", "demo", "demos", "karaoke", "tribute", "remix", "remixes",
    "instrumental", "instrumentals", "acoustic", "cover", "covers", "rehearsal", "rehearsals", "outtakes", "bbc",
    "soundcheck", "koncert", "nazivo", "8bit", "lullaby", "nightcore", "mashup", "unreleased", "rarities",
})

_TRACKNO = re.compile(r"^(?:[a-z]?\d{1,4}|\d{1,2}x\d{1,3}|cd\d{1,2}|disc\d{1,2}|\d{1,2}[a-z])$")
_YEAR = re.compile(r"^(?:19|20)\d\d$")
_BRACKETS = re.compile(r"[\(\[\{]([^\)\]\}]*)[\)\]\}]")
_AUDIO_EXT = re.compile(r"\.(flac|mp3|m4a|ogg|opus|wav|aac|wma|alac|ape|aiff?)$", re.I)
_FEAT = re.compile(r"\s(?:feat\.?|ft\.?|featuring)\s.*$", re.I)
_CJK = re.compile(r"[぀-ヿ㐀-䶿一-鿿가-힯豈-﫿]")
_SKIP_BRACKET = ("feat", "ft.", "ft ", "featuring", "with ", "prod", "from ", "as featured", "originally", "dedicated", "arr")


def fold(text: str) -> str:
    """Bez diakritiky, casefold, plnošířkové znaky na běžné."""
    text = unicodedata.normalize("NFKC", text or "")
    text = unicodedata.normalize("NFKD", text)
    return "".join(ch for ch in text if not unicodedata.combining(ch)).casefold()


_CONTRACTION = re.compile(r"(?<=[^\W\d_])['’`´](?=(?:s|t|m|re|ve|ll|d)\b)", re.I)


def tokens(text: str) -> list[str]:
    """Slova z písmen/číslic v jakémkoli písmu. Stažené tvary drží pohromadě
    ("Won't" = "Wont", "Winter's" = "Winters"). Souvislé CJK znaky (bez mezer)
    se rozpadnou na dvojice, ať se dá porovnávat ("雨の中で" -> 雨の, の中, 中て)."""
    out: list[str] = []
    text = _CONTRACTION.sub("", html.unescape(text or ""))
    for word in re.findall(r"[^\W_]+", fold(text).replace("_", " ")):
        if _CJK.search(word):
            chars = [c for c in word if not c.isspace()]
            if len(chars) == 1:
                out.append(chars[0])
            out.extend(a + b for a, b in zip(chars, chars[1:]))
        else:
            out.append(word)
    return out


def has_cjk(text: str) -> bool:
    return bool(_CJK.search(text or ""))


def _same(a: str, b: str) -> bool:
    if a == b:
        return True
    # Překlepy v katalogu / souborech ("Reruiting") -- jen u delších slov.
    return len(a) >= 5 and len(b) >= 5 and SequenceMatcher(None, a, b).ratio() >= 0.85


def _covered(word: str, pool) -> bool:
    return any(_same(word, p) for p in pool)


def _covered_joined(word: str, seq: list[str]) -> bool:
    """"Lenslife" = "Lens Life"."""
    return _covered(word, seq) or any(_same(word, a + b) for a, b in zip(seq, seq[1:]))


def core_title(title: str) -> str:
    """Název bez závorek, bez části za pomlčkou a bez "feat. X"."""
    core = _BRACKETS.sub(" ", title or "")
    core = re.split(r"\s+[-–—]\s+", core, maxsplit=1)[0]
    return _FEAT.sub("", core)


def core_tokens(title: str) -> set[str]:
    words = {t for t in tokens(core_title(title)) if t not in _STOP}
    longer = {w for w in words if not (len(w) == 1 and w.isascii() and w.isalpha())}
    return longer or words


def version_words(title: str) -> set[str]:
    """Slova verze z názvu skladby ("Car Radio (Ned's Version)" -> {"ned"},
    "Ride - Live in Mexico City" -> {"live", "mexico", "city"}). Kandidát je
    musí obsahovat."""
    parts = _BRACKETS.findall(title or "")
    dash = re.split(r"\s+[-–—]\s+", title or "", maxsplit=1)
    if len(dash) == 2:
        parts.append(dash[1])
    words: set[str] = set()
    for part in parts:
        if fold(part).strip().startswith(_SKIP_BRACKET):
            continue
        words |= {w for w in tokens(part) if len(w) >= 2 and not w.isdigit()}
    return words - NOISE - _STOP


def artist_tokens(artist: str | None) -> set[str]:
    """Hlavní interpret ("AURORA;Pomme", "X & Y", "X feat. Y" -> X), bez "the"."""
    main = re.split(r"\s*(?:;|,|/|&|\+|\bx\b|\bfeat\b\.?|\bft\b\.?|\bfeaturing\b|\bwith\b)\s*", artist or "", flags=re.I)[0]
    return {t for t in tokens(main) if t not in _STOP}


def artist_full_tokens(artist: str | None) -> set[str]:
    """Všechna slova jména ("Angus & Julia Stone" -> angus, julia, stone)."""
    return {t for t in tokens(artist or "") if t not in _STOP}


def artist_in(artist: str | None, text: str) -> bool:
    want = artist_tokens(artist)
    if not want:
        return True
    have = set(tokens(text))
    return all(_covered(w, have) for w in want)


def strip_ext(name: str) -> str:
    return _AUDIO_EXT.sub("", name or "")


_URL_BRACKET = re.compile(r"[\(\[\{][^\)\]\}]*(?:www\.|\.(?:com|net|org|ru|cz|sk|pl|info|to|me|cc)\b)[^\)\]\}]*[\)\]\}]", re.I)
_BARE_URL = re.compile(r"(?:www\.)?[a-z0-9-]+\.(?:com|net|org|ru|cz|sk|pl|info|to|me|cc)(?![a-z0-9])", re.I)


def clean_label(label: str) -> str:
    """Jméno souboru bez přípony a štítku webu ("[plixid.com]",
    "www.NewAlbumReleases.net_11 - ...")."""
    label = _URL_BRACKET.sub(" ", strip_ext(html.unescape(label or "")))
    return _BARE_URL.sub(" ", label)


def _scene_tail(label: str) -> str | None:
    """Značka release skupiny na konci scénového jména ("07-kvety-psi_hvezda-mcz")."""
    stripped = label.strip()
    if " " in stripped or not ("_" in stripped or stripped.count("-") >= 2):
        return None
    last = re.split(r"-", stripped)[-1]
    return fold(last) if 2 <= len(last) <= 6 and re.fullmatch(r"[A-Za-z0-9]+", last) else None


def match_label(
    title: str,
    label: str,
    *,
    artist: str | None = None,
    album: str | None = None,
    context: str = "",
) -> str | None:
    """Sedí `label` (název videa / jméno souboru bez složky) na skladbu?

    `context` = další text, ve kterém smí být slova verze a nesmí být
    značky jiné verze (složka alba na Soulseeku). Vrací None = sedí,
    jinak důvod."""
    label = clean_label(label)
    title_core = core_tokens(title)
    named = set(tokens(title)) | set(tokens(album or ""))
    asked = named | artist_tokens(artist)
    label_words = set(tokens(label))
    context_words = set(tokens(context))
    all_words = label_words | context_words

    # 1) Značky jiné verze (live, remix, intro, session...). Ve složce jen ty
    #    jednoznačné -- "Folk Blues Sessions" je studiové album.
    marks = {w for w in label_words if w in MARKERS and w not in asked}
    marks |= {w for w in context_words if w in CONTEXT_MARKERS and w not in asked}
    if "full" in label_words and "album" in label_words and not {"full", "album"} <= asked:
        marks.add("full album")
    if marks:
        return f"jiná verze ({', '.join(sorted(marks))})"

    # 2) Verze, kterou skladba nese v názvu, musí kandidát nést taky --
    #    leda je soubor přímo ze složky toho alba ("Dance of the Dream Man
    #    (Instrumental)" ze "Soundtrack From Twin Peaks").
    need = version_words(title)
    missing = {w for w in need if not _covered(w, all_words)}
    album_core = core_tokens(album or "")
    if missing and not (album_core and all(_covered(w, all_words) for w in album_core)):
        return f"chybí verze ({', '.join(sorted(missing))})"

    # 3) Obsah závorek kandidáta: jen šum, interpret, album nebo verze ze
    #    zadání ("22 (Taylor's Version)" není "22").
    if not has_cjk(title):  # přeložené názvy bývají v závorce
        for part in _BRACKETS.findall(label):
            if fold(part).strip().startswith(_SKIP_BRACKET):
                continue
            extra = {
                w for w in tokens(part)
                if w not in NOISE and w not in _STOP and len(w) > 1 and not _YEAR.match(w) and not w.isdigit()
                and not _covered(w, named)
            }
            if extra:
                return f"jiná verze ({', '.join(sorted(extra))})"

    # 4) Jádro: po odebrání interpreta, alba, čísla stopy a šumu musí zbýt
    #    PŘESNĚ název skladby -- nic víc, nic míň.
    if not title_core:
        return "název bez porovnatelných slov"
    rest = _rest(label, title_core, artist, album_core, context_words, keep_brackets=False)
    if any(not _covered(t, rest) for t in title_core):
        # "(I'm Your) Hoochie Coochie Man" -- část názvu v závorce.
        rest = _rest(label, title_core, artist, album_core, context_words, keep_brackets=True)
    rest = _join_split_words(rest, title_core)
    missing_core = {t for t in title_core if not _covered(t, rest)}
    if missing_core:
        return f"chybí název ({', '.join(sorted(missing_core))})"
    extra = {t for t in rest if not _covered(t, title_core)}
    if extra and extra == {_scene_tail(label)}:
        extra = set()
    if extra:
        return f"jiná skladba ({', '.join(sorted(extra))})"
    return None


def _join_split_words(rest: list[str], title_core: set[str]) -> list[str]:
    """"Lens Life" v souboru = "Lenslife" v katalogu (a naopak se nic neslučuje)."""
    out = list(rest)
    for word in title_core:
        if _covered(word, out):
            continue
        for i in range(len(out) - 1):
            if _same(word, out[i] + out[i + 1]):
                out[i : i + 2] = [word]
                break
    return out


def _rest(label, title_core, artist, album_core, context_words, *, keep_brackets: bool) -> list[str]:
    text = label if keep_brackets else _BRACKETS.sub(" ", label)
    if keep_brackets:
        text = re.sub(r"[\(\)\[\]\{\}]", " ", text)
    segments = [_FEAT.sub("", s) for s in re.split(r"\s+[-–—|~]+\s+|\s+/\s+", text)]
    if len(segments) > 1 and context_words:
        # Celá část jména = název složky (album/interpret: "Laufey - Bewitched -
        # 10 From the Start" ve složce "[2023] Bewitched") pryč -- ale ne ta,
        # která nese název skladby ("Cherry Blossom" ve složce "Cherry Blossom").
        def droppable(seg: str) -> bool:
            words = {w for w in tokens(seg) if w not in _STOP}
            return bool(words) and words <= context_words and not all(_covered(t, words) for t in title_core)

        segments = [s for s in segments if not droppable(s)]
    rest = [t for t in tokens(" ".join(segments)) if t not in _STOP]
    # Interpret se odebere jen celý ("twenty one pilots" nesmí sebrat "One"
    # z "One Way", když ve jméně souboru interpret není); napřed celé jméno
    # ("Angus & Julia Stone"), pak hlavní interpret ("AURORA;Pomme" -> AURORA).
    for a_tok in (artist_full_tokens(artist), artist_tokens(artist)):
        if a_tok and not a_tok <= title_core and all(_covered(t, rest) for t in a_tok):
            rest = [t for t in rest if not _covered(t, a_tok) or _covered(t, title_core)]
            break
    if album_core and album_core != title_core and not album_core <= title_core:
        # Album se odebere, jen když je v názvu celé.
        if all(_covered(t, rest) for t in album_core):
            rest = [t for t in rest if not _covered(t, album_core) or _covered(t, title_core)]
    return [
        t for t in rest
        if _covered(t, title_core)
        or not (t in NOISE or _YEAR.match(t) or _TRACKNO.match(t) or (len(t) == 1 and t.isascii() and t.isalpha()))
    ]


def duration_ok(expected_s: float | None, actual_s: float | None, *, strict: bool = True) -> bool:
    """Délka sedí? `strict` = vysoká jistota (max(5 s, 3 %)), jinak
    max(12 s, 7 %) -- jiný fade / mírně jiný master, ale ne jiná nahrávka."""
    if not expected_s or not actual_s:
        return False
    tol = max(5.0, expected_s * 0.03) if strict else max(12.0, expected_s * 0.07)
    return abs(actual_s - expected_s) <= tol
