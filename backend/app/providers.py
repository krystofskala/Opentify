"""MediaProvider konektory — jediné místo, kde by měla sedět znalost o tom,
odkud se soubor fyzicky bere. Worker (app/worker.py) na konkrétním
provideru nezávisí, jen na `MediaProvider` protokolu.

Providery:
  - `SlskdProvider`   -- primární zdroj, REST konektor na lokální slskd
                         (Soulseek daemon), preferuje lossless (FLAC).
  - `YoutubeProvider` -- fallback přes yt-dlp, použije se jen když slskd
                         nic nenajde nebo stahování selže; po stažení
                         dotáhne MBID/interpreta/název do tagů (mutagen),
                         protože YouTube o MBID nic neví.
  - `CompositeProvider` -- zkouší providery v zadaném pořadí, padá na
                         dalšího jak při prázdném `resolve()`, tak při
                         výjimce ve `fetch()` (viz jeho docstring).
  - `PlaceholderProvider` -- čistě vývojová náhrada beze změny, pro
                         end-to-end test pipeline bez závislosti na
                         slskd/yt-dlp (`MEDIA_PROVIDER=placeholder`).

Přesné REST tvary slskd (cesty, JSON pole) se mezi verzemi mění -- ověř si
je proti `/swagger` běžící instance, než tohle nasadíš na jinou verzi než
tu, se kterou se to psalo (slskd ~0.20.x).
"""

from __future__ import annotations

import asyncio
import dataclasses
import glob
import logging
import os
import re
import shutil
import time
import unicodedata
from dataclasses import dataclass, field
from pathlib import Path
from typing import Awaitable, Callable, Protocol, Sequence

import httpx

from app.catalog.rate_limit import AsyncRateLimiter

logger = logging.getLogger("vault.providers")

ProgressCallback = Callable[[int], Awaitable[None]]

# Zavolá se (nejvýš jednou za `fetch()`) hned, jak provider najde/vytvoří
# soubor na disku -- i uprostřed stahování, ne až na konci. Umožňuje
# `GET /tracks/{id}/stream` začít servírovat ještě rostoucí soubor (viz
# `routes/provisioning.py:_tail_growing_file`), místo čekání na úplné
# dokončení. Jen `SlskdProvider` ho reálně volá -- stahuje rovnou ve
# finálním formátu (FLAC/MP3), takže růst souboru je bezpečně streamovatelný.
# `YoutubeProvider` ho nevolá: nativní m4a z YouTube je hotové za ~3 s, dřív
# než by se progresivní stream vůbec vyplatil.
OnFileLocated = Callable[[Path], Awaitable[None]]


def _normalize(text: str) -> str:
    """Bez diakritiky, malá písmena, jen alfanumerické tokeny oddělené
    mezerou -- pro porovnání názvu skladby s názvem souboru na Soulseeku."""
    text = unicodedata.normalize("NFKD", text)
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    return " ".join(re.findall(r"[a-z0-9]+", text.lower()))


# Slova, co v názvech složek/souborů často chybí nebo se píšou jinak.
_SOULSEEK_STOPWORDS = {"the", "feat", "ft", "featuring", "and", "a"}


def _title_tokens(title: str) -> set[str]:
    # Závorky/hranaté závorky ("(Remastered 2011)", "[Live]") v názvech
    # souborů často chybí nebo se liší -- do shody se nepočítají.
    core = re.sub(r"[\(\[].*?[\)\]]", " ", title)
    return {t for t in _normalize(core).split() if len(t) >= 2}


# Obecná slova v závorkách, která verzi nemění ("(Remastered 2011)",
# "(feat. X)", "- Single Version").
_GENERIC_QUALIFIER = {
    "version", "remaster", "remastered", "mix", "edit", "original", "radio", "single", "album", "mono",
    "stereo", "feat", "ft", "featuring", "with", "deluxe", "bonus", "track", "explicit", "clean", "from",
    "the", "and", "of", "official", "audio", "video", "lyric", "lyrics", "hd", "hq", "digital",
}


def _qualifier_tokens(title: str) -> set[str]:
    """Slova verze z názvu skladby -- obsah závorek a část za pomlčkou
    ("Car Radio (Ned's Version)" -> {"ned"}, "Ride - Live in Mexico City"
    -> {"live", "mexico", "city"}). Stahovaný soubor je MUSÍ obsahovat,
    jinak je to jiná verze (živě: celé album "Ned's Version" se stáhlo
    v původních verzích, "Trees" dokonce jako jiná píseň)."""
    parts = re.findall(r"[\(\[]([^\)\]]*)[\)\]]", title)
    dash = re.split(r"\s+[-–—]\s+", title, maxsplit=1)
    if len(dash) == 2:
        parts.append(dash[1])
    words: set[str] = set()
    for part in parts:
        low = part.lower().strip()
        if low.startswith(("feat", "ft.", "ft ", "with ", "from ")):
            continue
        words |= {w for w in _normalize(part).split() if len(w) >= 2 and not w.isdigit()}
    # "ned's" -> "ned s" po normalizaci; jednopísmenné části odpadly výš.
    return words - _GENERIC_QUALIFIER


def _album_match(album_title: str | None, have: set[str]) -> bool:
    """Kandidát nese název právě toho alba, ke kterému skladba patří."""
    words = _title_tokens(album_title or "") - _GENERIC_QUALIFIER
    return bool(words) and words <= have


def _matches_title(title: str, candidate_text: str, album_title: str | None = None) -> bool:
    """Přísná shoda: celý název skladby (bez závorek) i slova verze musí
    v kandidátovi být; jiná verze, kterou název nenese, ne. Výjimka: soubor
    přímo ze správného alba (složka/název alba) -- to je přesně ta skladba,
    i když verzi v názvu souboru nemá ("Dance of the Dream Man
    (Instrumental)" ze "Soundtrack From Twin Peaks")."""
    have = set(_normalize(candidate_text).split())
    core = _title_tokens(title)
    if core and not core <= have:
        return False
    if not _qualifier_tokens(title) <= have and not _album_match(album_title, have):
        return False
    asked = set(_normalize(title).split())
    return not any(m in have and m not in asked for m in _VERSION_MARKERS)


_VERSION_MARKERS = (
    "live", "acoustic", "cover", "remix", "karaoke", "instrumental", "piano", "ukulele", "reaction", "sped",
    "slowed", "nightcore", "concert", "demo", "unplugged", "orchestral", "lullaby", "8bit", "tribute", "mashup",
)


@dataclass
class TrackMetadata:
    """To, co worker o skladbě ví z DB (`app/worker.py:_start_job`) a co
    providery potřebují jak k vyhledání (`title`/`artist_name`), tak
    k dotažení tagů po stažení ze zdroje, který o MBID nic neví (`mbid`)."""

    recording_id: str
    title: str
    artist_name: str | None = None
    mbid: str | None = None
    duration_ms: int | None = None
    # Kolik nejlepších kandidátů přeskočit (opakované stažení po špatném
    # výsledku -- jinak by se stáhlo totéž video znovu).
    skip_candidates: int = 0
    # Přesné YouTube video (skladba z odkazu na YouTube / album jen na
    # YouTube) -- stáhne se přímo ono, žádné hledání ani Soulseek.
    youtube_id: str | None = None
    # Přesná skladba ze SoundCloudu (import odkazem, "Nevydané a vzácné").
    soundcloud_url: str | None = None
    # Zdroje, které uživatel označil jako špatnou verzi ("Špatná verze --
    # stáhnout jinou"): `slskd:{user}|{soubor}`, `youtube:{id}`.
    rejected_sources: tuple[str, ...] = ()
    # Album, ze kterého skladba je (konkrétní vydání) -- soubor ze složky toho
    # alba / video s jeho názvem má přednost (správná verze, ne live/remaster
    # z jiné desky).
    album_title: str | None = None
    # Soubor z vybrané složky celého alba (`app/library/album_download.py`):
    # {"username", "filename", "size"} -- stáhne se rovnou on, bez hledání.
    preferred_source: dict | None = None

    @property
    def search_query(self) -> str:
        return f"{self.artist_name} {self.title}".strip() if self.artist_name else self.title.strip()

    @property
    def soulseek_query(self) -> str:
        """Soulseek hledá podřetězce CELÉ cesty a musí sedět KAŽDÉ slovo --
        interpunkce/"&"/apostrofy ("I’d") nebo text v závorkách tak dřív
        shodily hledání na nulu. Jen slova z písmen/číslic, bez závorek,
        bez jednoznakových zbytků po apostrofech."""
        title = re.sub(r"[\(\[].*?[\)\]]", " ", self.title)
        # "AURORA;Pomme", "X & Y", "X feat. Y" -> jen hlavní interpret (méně
        # povinných slov = víc zásahů; skladbu stejně ověří `_rank`).
        artist = re.split(r"\s*(?:;|,|/|&|\bfeat\b\.?|\bft\b\.?)\s*", self.artist_name or "", flags=re.I)[0]
        text = f"{artist} {title}"
        words = [w for w in re.findall(r"\w+", text) if len(w) >= 2 and w.lower() not in _SOULSEEK_STOPWORDS]
        return " ".join(words) or self.search_query


@dataclass
class ProviderCandidate:
    source_provider: str
    source_ref: str
    extra: dict = field(default_factory=dict)


@dataclass
class FetchResult:
    """Výsledek `MediaProvider.fetch()` -- `source_provider`/`format`/
    `bitrate_kbps` sem patří (ne na `ProviderCandidate`), protože
    `CompositeProvider` může fakticky stáhnout jiným providerem, než který
    našel první `candidate` (fallback při chybě `fetch()`, viz jeho
    docstring) -- výsledná metadata musí odpovídat tomu, kdo soubor OPRAVDU
    stáhl."""

    path: Path
    format: str
    source_provider: str
    bitrate_kbps: int | None = None
    # Odkaz na zdroj (YouTube video) -- ukáže se u skladby a ve sdílení.
    source_url: str | None = None
    # Přesný zdroj souboru (viz `TrackMetadata.rejected_sources`).
    source_key: str | None = None


class MediaProvider(Protocol):
    async def resolve(self, track: TrackMetadata, *, interactive: bool = False) -> ProviderCandidate | None: ...

    async def fetch(
        self,
        track: TrackMetadata,
        candidate: ProviderCandidate,
        dest_stem: Path,
        on_progress: ProgressCallback,
        on_file_located: OnFileLocated,
    ) -> FetchResult:
        """`dest_stem` je cílová cesta BEZ přípony (worker nezná formát
        předem) -- provider si připojí tu svou (`.flac`, `.mp3`, ...) a
        vrátí skutečnou cestu ve `FetchResult.path`. `on_file_located` viz
        jeho docstring výš -- volitelné zavolat, ne všechny providery to
        umí/dává smysl."""
        ...


class PlaceholderProvider:
    """Čistě vývojová náhrada: nesahá nikam ven, jen simuluje zpoždění a
    zapíše syntetická data, aby šel celý pipeline (PENDING -> RUNNING ->
    AVAILABLE, progress eventy, checksum) end-to-end odzkoušet bez závislosti
    na reálném zdroji."""

    async def resolve(self, track: TrackMetadata, *, interactive: bool = False) -> ProviderCandidate | None:
        return ProviderCandidate(source_provider="placeholder", source_ref=track.recording_id)

    async def fetch(
        self,
        track: TrackMetadata,
        candidate: ProviderCandidate,
        dest_stem: Path,
        on_progress: ProgressCallback,
        on_file_located: OnFileLocated,
    ) -> FetchResult:
        dest_path = dest_stem.with_suffix(".audio")
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        steps = 5
        tmp_path = dest_path.with_suffix(dest_path.suffix + ".part")
        with open(tmp_path, "wb") as f:
            for i in range(steps):
                await asyncio.sleep(0.2)
                f.write(b"\x00" * 4096)  # syntetická data, ne validní audio
                await on_progress(int((i + 1) / steps * 100))
        tmp_path.replace(dest_path)
        return FetchResult(path=dest_path, format="audio", source_provider="placeholder")


class _PeerFailed(Exception):
    """Jeden konkrétní Soulseek peer nevyšel (odmítl, frontí, zasekl se) --
    `SlskdProvider.fetch()` pak zkusí dalšího kandidáta z téhož hledání."""


@dataclass(frozen=True)
class _SlskdProfile:
    # Tvrdý strop hledání -- slskd sám pošle odpovědi obvykle do 1.5-3.5 s,
    # "dokončení" hledání ale trvá ~20 s (živě změřeno). Čekat na dokončení
    # bylo hlavní zdržení prvního přehrání.
    search_cap_s: float
    # Jak dlouho ještě sbírat odpovědi po prvním "dobrém" kandidátovi.
    settle_s: float
    # Peer, který do tohohle času nepošle ani bajt (typicky "Queued,
    # Remotely"), se zruší a jde se na dalšího.
    start_timeout_s: float
    # Rozběhnutý přenos, co tak dlouho nepřibyl ani bajt.
    stall_timeout_s: float
    max_peers: int


# Rozestup hledání na Soulseeku napříč všemi workery (Redis, viz rate_limit).
_slskd_search_limiter = AsyncRateLimiter(min_interval_seconds=1.2, key="slskd-search")


class SlskdProvider:
    """Konektor na slskd (https://github.com/slskd/slskd) REST API.

    Dva profily:
      - `interactive` (uživatel zmáčkl Přehrát a čeká): krátké hledání
        s early-exitem, peer vybraný hlavně podle toho, jak rychle soubor
        pošle (volný upload slot, rychlost, fronta), rychlé vzdání se
        nerozběhnutého peeru.
      - background (prefetch/fronta): delší hledání, kvalita (FLAC) má
        přednost, trpělivější timeouty.

    Auth: `X-API-Key` header. Soubory po dokončení transferu leží někde pod
    `downloads_dir` (slskd strukturu zplošťuje podle vzdálené cesty, ne podle
    uživatele) -- hledá se rekurzivně podle jména, viz `_locate_downloaded_file`.
    """

    PREFERRED_EXTENSIONS = (".flac", ".mp3", ".m4a", ".ogg")

    INTERACTIVE = _SlskdProfile(search_cap_s=8.0, settle_s=1.0, start_timeout_s=8.0, stall_timeout_s=10.0, max_peers=3)
    # Na pozadí nikdo nečeká (a kliknutí přidá YouTube závod) -- víc peerů,
    # ať se víc stahuje z Soulseeku (týden: 62 % YouTube).
    BACKGROUND = _SlskdProfile(search_cap_s=15.0, settle_s=3.0, start_timeout_s=45.0, stall_timeout_s=30.0, max_peers=6)
    # Složka celého alba od jednoho člověka: posílá skladbu po skladbě, ostatní
    # čekají v jeho frontě -- trpělivě (živě: 45 s limit poslal 11/16 jinam).
    ALBUM = _SlskdProfile(search_cap_s=15.0, settle_s=3.0, start_timeout_s=600.0, stall_timeout_s=60.0, max_peers=1)

    # Peer, co nedávno odmítl/zaseknul přenos, se chvíli vůbec nezkouší.
    _BLOCKLIST_S = 30 * 60

    def __init__(
        self,
        base_url: str | None = None,
        api_key: str | None = None,
        downloads_dir: Path | None = None,
        *,
        download_timeout_s: float = 300.0,
        poll_interval_s: float = 0.5,
    ) -> None:
        self.base_url = (base_url or os.environ.get("SLSKD_URL", "http://slskd:5030")).rstrip("/")
        self.api_key = api_key or os.environ.get("SLSKD_API_KEY", "")
        self.downloads_dir = downloads_dir or Path(
            os.environ.get("SLSKD_DOWNLOADS_DIR", "/data/slskd-downloads")
        )
        self.download_timeout_s = download_timeout_s
        self.poll_interval_s = poll_interval_s
        self._blocked_until: dict[str, float] = {}

    def _headers(self) -> dict[str, str]:
        return {"X-API-Key": self.api_key} if self.api_key else {}

    def _block(self, username: str) -> None:
        self._blocked_until[username] = time.monotonic() + self._BLOCKLIST_S

    def _is_blocked(self, username: str) -> bool:
        until = self._blocked_until.get(username)
        return until is not None and until > time.monotonic()

    # ------------------------------------------------------------------
    # Hledání
    # ------------------------------------------------------------------

    async def search_raw(self, query: str, cap_s: float = 20.0) -> list[dict]:
        """Surové odpovědi hledání (pro výběr složky celého alba)."""
        async with httpx.AsyncClient(base_url=self.base_url, headers=self._headers(), timeout=10.0) as client:
            for attempt in range(4):
                await _slskd_search_limiter.wait()
                created = await client.post(
                    "/api/v0/searches", json={"searchText": query, "searchTimeout": int(cap_s * 1000)}
                )
                if created.status_code != 429:
                    break
                await asyncio.sleep(2.0 * (attempt + 1))
            created.raise_for_status()
            search_id = created.json()["id"]
            loop = asyncio.get_running_loop()
            started = loop.time()
            try:
                while loop.time() - started < cap_s:
                    payload = (await client.get(f"/api/v0/searches/{search_id}")).json()
                    if bool(payload.get("isComplete")) or str(payload.get("state", "")).lower().startswith("completed"):
                        break
                    await asyncio.sleep(1.0)
                responses = await client.get(f"/api/v0/searches/{search_id}/responses")
                responses.raise_for_status()
                return [r for r in responses.json() if r.get("username") and not self._is_blocked(r["username"])]
            finally:
                try:
                    await client.delete(f"/api/v0/searches/{search_id}")
                except httpx.HTTPError:
                    pass

    async def resolve(self, track: TrackMetadata, *, interactive: bool = False) -> ProviderCandidate | None:
        pref = track.preferred_source
        if (
            pref
            and not self._is_blocked(pref["username"])
            and f"slskd:{pref['username']}|{pref['filename']}" not in track.rejected_sources
        ):
            # Soubor ze složky celého alba -- jedna verze pro celé album.
            peer = {k: pref.get(k) for k in ("username", "filename", "size", "bitrate_kbps")}
            return ProviderCandidate(
                source_provider="slskd",
                source_ref=f"{peer['username']}/{peer['filename']}",
                extra={**peer, "alternates": [], "interactive": interactive, "preferred": True},
            )
        query = track.soulseek_query
        if not query:
            return None
        profile = self.INTERACTIVE if interactive else self.BACKGROUND
        async with httpx.AsyncClient(base_url=self.base_url, headers=self._headers(), timeout=10.0) as client:
            # Hledání přes společnou frontu všech workerů s rozestupem -- rádio
            # s 50 skladbami jich dřív spustilo desítky naráz a slskd vracel
            # 429 Too Many Requests (živě: skladby "Ve frontě" donekonečna).
            for attempt in range(4):
                await _slskd_search_limiter.wait()
                created = await client.post(
                    "/api/v0/searches",
                    # slskd ať hledá jen tak dlouho, jak my čekáme -- jinak by
                    # zbytečně držel otevřené hledání dalších ~15 s.
                    json={"searchText": query, "searchTimeout": int(profile.search_cap_s * 1000)},
                )
                if created.status_code != 429:
                    break
                await asyncio.sleep(2.0 * (attempt + 1))
            created.raise_for_status()
            search_id = created.json()["id"]

            loop = asyncio.get_running_loop()
            started = loop.time()
            first_good_at: float | None = None
            ranked: list[tuple[float, str, dict]] = []
            seen_responses = -1
            try:
                while True:
                    now = loop.time()
                    status_resp = await client.get(f"/api/v0/searches/{search_id}")
                    status_resp.raise_for_status()
                    payload = status_resp.json()
                    count = int(payload.get("responseCount") or 0)
                    complete = bool(payload.get("isComplete")) or str(payload.get("state", "")).lower().startswith(
                        "completed"
                    )
                    if count != seen_responses and (count > 0 or complete):
                        seen_responses = count
                        responses = await client.get(f"/api/v0/searches/{search_id}/responses")
                        responses.raise_for_status()
                        ranked = self._rank(responses.json(), track, interactive=interactive)
                        if first_good_at is None and ranked and self._is_good(ranked[0], interactive):
                            first_good_at = now
                    if complete:
                        break
                    if first_good_at is not None and now - first_good_at >= profile.settle_s:
                        break
                    if now - started >= profile.search_cap_s:
                        break
                    await asyncio.sleep(self.poll_interval_s)
            finally:
                # Úklid -- slskd si jinak hromadí stovky starých hledání.
                try:
                    await client.delete(f"/api/v0/searches/{search_id}")
                except httpx.HTTPError:
                    pass

        logger.info(
            "slskd hledání '%s' (%s): %d kandidátů za %.1f s",
            query,
            "interactive" if interactive else "background",
            len(ranked),
            loop.time() - started,
        )
        if not ranked:
            return None
        peers = [
            {
                "username": username,
                "filename": f["filename"],
                "size": f.get("size", 0),
                "bitrate_kbps": f.get("bitRate"),
            }
            for _score, username, f in ranked[: profile.max_peers]
        ]
        best = peers[0]
        return ProviderCandidate(
            source_provider="slskd",
            source_ref=f"{best['username']}/{best['filename']}",
            extra={**best, "alternates": peers[1:], "interactive": interactive},
        )

    def _rank(self, search_responses: list[dict], track: TrackMetadata, *, interactive: bool) -> list[tuple[float, str, dict]]:
        """Seřadí soubory ze všech odpovědí -- dřív se bral první FLAC bez
        ohledu na to, jestli má peer volný slot nebo frontu stovek souborů,
        takže "nejlepší" kandidát často visel v "Queued, Remotely" až do
        300s timeoutu, než se spadlo na YouTube."""
        wanted = _title_tokens(track.title)
        qualifier = _qualifier_tokens(track.title)
        asked_words = set(_normalize(track.title).split())
        album_words = _title_tokens(track.album_title or "")
        out: list[tuple[float, str, dict]] = []
        seen: set[tuple[str, str]] = set()
        for response in search_responses:
            username = response.get("username")
            if not username or self._is_blocked(username):
                continue
            free = bool(response.get("hasFreeUploadSlot"))
            queue = int(response.get("queueLength") or 0)
            speed = int(response.get("uploadSpeed") or 0)  # B/s
            for f in response.get("files", []):
                filename = f.get("filename", "")
                ext = Path(filename.replace("\\", "/")).suffix.lower()
                if ext not in self.PREFERRED_EXTENSIONS:
                    continue
                if (username, filename) in seen:
                    continue
                seen.add((username, filename))
                if f"slskd:{username}|{filename}" in track.rejected_sources:
                    continue  # uživatel ho označil jako špatnou verzi
                # Délka úplně jiná = jiná nahrávka, i když název sedí (živě:
                # "Holding on to You" byla ukulele verze jiné písně, 2:38).
                length = f.get("length")
                if length and track.duration_ms:
                    target = track.duration_ms / 1000
                    if abs(float(length) - target) > max(20.0, target * 0.15):
                        continue
                if wanted:
                    have = set(_normalize(filename.rsplit("\\", 1)[-1]).split())
                    if len(wanted & have) < max(1, round(len(wanted) * 0.8)):
                        continue  # jiná skladba ze stejného alba/interpreta
                # Verze z názvu ("Ned's Version", "Live in ...") musí být
                # v cestě (soubor nebo složka alba); jiná verze ne.
                path_words = set(_normalize(filename.replace("\\", " ")).split())
                if not qualifier <= path_words and not _album_match(track.album_title, path_words):
                    continue
                base_words = set(_normalize(filename.rsplit("\\", 1)[-1]).split())
                if any(m in base_words and m not in asked_words for m in _VERSION_MARKERS):
                    continue
                size = int(f.get("size") or 0)
                bitrate = f.get("bitRate")
                if ext == ".flac":
                    quality = 3.0
                elif ext == ".mp3":
                    quality = 2.0 if (bitrate is None or bitrate >= 256) else (1.2 if bitrate >= 192 else 0.4)
                else:
                    quality = 1.5
                est_s = size / max(speed, 50_000) if size else 30.0
                if interactive:
                    score = (1000 if free else 0) - est_s * 10 - queue * 50 + quality * 25
                else:
                    score = (500 if free else 0) - queue * 20 + quality * 200 - est_s
                # Soubor ze složky správného alba: výrazná přednost (ne ale
                # víc než volný slot u interaktivního přehrání).
                if album_words:
                    folder = set(_normalize(filename.replace("\\", "/").rsplit("/", 1)[0]).split())
                    if len(album_words & folder) >= max(1, round(len(album_words) * 0.8)):
                        score += 300 if interactive else 400
                f = {**f, "_free": free, "_speed": speed, "_est_s": est_s, "_quality": quality}
                out.append((score, username, f))
        out.sort(key=lambda c: c[0], reverse=True)
        return out

    @staticmethod
    def _is_good(candidate: tuple[float, str, dict], interactive: bool) -> bool:
        _score, _user, f = candidate
        if interactive:
            return f["_free"] and f["_speed"] >= 300_000 and f["_est_s"] <= 15
        return f["_free"] and f["_quality"] >= 2.0

    # ------------------------------------------------------------------
    # Stahování
    # ------------------------------------------------------------------

    async def fetch(
        self,
        track: TrackMetadata,
        candidate: ProviderCandidate,
        dest_stem: Path,
        on_progress: ProgressCallback,
        on_file_located: OnFileLocated,
    ) -> FetchResult:
        interactive = bool(candidate.extra.get("interactive"))
        preferred = bool(candidate.extra.get("preferred"))
        profile = self.INTERACTIVE if interactive else (self.ALBUM if preferred else self.BACKGROUND)
        peers = [candidate.extra, *candidate.extra.get("alternates", [])]
        located = False

        async def located_once(path: Path) -> None:
            nonlocal located
            located = True
            await on_file_located(path)

        last_error: Exception | None = None
        for peer in peers:
            try:
                return await self._fetch_from_peer(peer, profile, dest_stem, on_progress, located_once)
            except _PeerFailed as exc:
                last_error = exc
                if not preferred:  # složku alba zkusí i další skladby
                    self._block(peer["username"])
                logger.info("slskd peer %s nevyšel: %s", peer["username"], exc)
                if located:
                    # Klient už přehrává rostoucí soubor OD TOHOHLE peeru --
                    # jiný peer = jiný soubor, plynule na něj navázat nejde.
                    break
        if preferred and not located:
            # Složka alba nevyšla -- normální hledání na Soulseeku, ne hned YouTube.
            plain = dataclasses.replace(track, preferred_source=None)
            fallback = await self.resolve(plain, interactive=interactive)
            if fallback is not None:
                return await self.fetch(plain, fallback, dest_stem, on_progress, on_file_located)
        raise RuntimeError(f"slskd: žádný peer soubor nedodal ({last_error})")

    async def _fetch_from_peer(
        self,
        peer: dict,
        profile: _SlskdProfile,
        dest_stem: Path,
        on_progress: ProgressCallback,
        on_file_located: OnFileLocated,
    ) -> FetchResult:
        username = peer["username"]
        filename = peer["filename"]
        # Soulseek cesty mají zpětná lomítka i na Linuxu -- basename ručně.
        basename = filename.rsplit("\\", 1)[-1]
        remote_dir = filename.rsplit("\\", 2)[-2] if filename.count("\\") >= 1 else ""
        source_path: Path | None = None
        since = time.time() - 5

        def locate() -> Path | None:
            return self._locate_downloaded_file(basename, remote_dir, since)

        async with httpx.AsyncClient(base_url=self.base_url, headers=self._headers(), timeout=10.0) as client:
            try:
                queued = await client.post(
                    f"/api/v0/transfers/downloads/{username}",
                    json=[{"filename": filename, "size": peer.get("size", 0)}],
                )
                # 409 = ten soubor od toho peeru už ve frontě je (dřívější
                # pokus) -- navázat na něj, ne vzdát (5 selhání za týden).
                if queued.status_code != 409:
                    queued.raise_for_status()
            except httpx.HTTPError as exc:
                # 429/5xx od slskd -- zkusit dalšího peera, ne shodit celý slskd.
                raise _PeerFailed(f"slskd nezafrontil ({exc})") from exc
            poll_errors = 0

            loop = asyncio.get_running_loop()
            started = loop.time()
            last_bytes = 0
            last_change = started
            transfer: dict | None = None
            try:
                while True:
                    now = loop.time()
                    limit = max(self.download_timeout_s, profile.start_timeout_s + 600)
                    if now - started > limit:
                        await self._cancel(client, username, transfer)
                        raise _PeerFailed(f"nedokončeno do {limit:.0f} s")

                    try:
                        transfers_resp = await client.get(f"/api/v0/transfers/downloads/{username}")
                        transfers_resp.raise_for_status()
                    except httpx.HTTPError as exc:
                        poll_errors += 1
                        if poll_errors >= 6:
                            await self._cancel(client, username, transfer)
                            raise _PeerFailed(f"slskd neodpovídá ({exc})") from exc
                        await asyncio.sleep(min(2.0 * poll_errors, 10.0))
                        continue
                    poll_errors = 0
                    transfer = self._find_transfer(transfers_resp.json(), filename)
                    if transfer is not None:
                        transferred = int(transfer.get("bytesTransferred", 0))
                        await on_progress(min(int(transfer.get("percentComplete", 0)), 99))

                        if transferred > last_bytes:
                            last_bytes = transferred
                            last_change = now
                        if source_path is None and transferred > 0:
                            found = await asyncio.to_thread(locate)
                            if found is not None:
                                source_path = found
                                await on_file_located(found)

                        state = str(transfer.get("state", "")).lower()
                        if "completed" in state:
                            if "succeeded" in state:
                                break
                            # Rejected / TimedOut / Errored / Cancelled / Aborted --
                            # dřív se chytaly jen Errored/Cancelled a zbytek se
                            # točil až do 300s timeoutu.
                            raise _PeerFailed(f"stav {transfer.get('state')}")

                    if last_bytes == 0 and now - started > profile.start_timeout_s:
                        await self._cancel(client, username, transfer)
                        state = transfer.get("state") if transfer else "nezafrontěno"
                        raise _PeerFailed(f"nezačal posílat do {profile.start_timeout_s:.0f} s ({state})")
                    if last_bytes > 0 and now - last_change > profile.stall_timeout_s:
                        await self._cancel(client, username, transfer)
                        raise _PeerFailed(f"přenos se zasekl na {last_bytes} B")

                    await asyncio.sleep(self.poll_interval_s)
            except asyncio.CancelledError:
                # Závod skončil jinak (YouTube vyhrál / job zrušen) -- ať transfer
                # nezůstane viset ve frontě peeru a později nestáhne sirotka.
                await asyncio.shield(self._cancel(client, username, transfer))
                raise
            except _PeerFailed:
                raise
            except Exception:
                await self._cancel(client, username, transfer)
                raise

        if source_path is None:
            source_path = await asyncio.to_thread(locate)
        if source_path is None:
            raise _PeerFailed(f"dokončený transfer '{basename}' se nenašel pod {self.downloads_dir}")

        dest_path = dest_stem.with_suffix(source_path.suffix.lower())
        dest_path.parent.mkdir(parents=True, exist_ok=True)
        # `shutil.move` mezi Docker volumes = kopie + smazání; otevřený handle
        # progresivního streamu (`_tail_growing_file`) přežije díky POSIX inode.
        await asyncio.to_thread(shutil.move, str(source_path), str(dest_path))
        await on_progress(100)

        return FetchResult(
            path=dest_path,
            format=dest_path.suffix.lstrip("."),
            source_provider="slskd",
            bitrate_kbps=peer.get("bitrate_kbps"),
            source_key=f"slskd:{username}|{filename}",
        )

    @staticmethod
    async def _cancel(client: httpx.AsyncClient, username: str, transfer: dict | None) -> None:
        if not transfer or not transfer.get("id"):
            return
        try:
            await client.delete(
                f"/api/v0/transfers/downloads/{username}/{transfer['id']}", params={"remove": "true"}
            )
        except httpx.HTTPError:
            pass

    def _locate_downloaded_file(self, basename: str, remote_dir: str = "", since: float = 0.0) -> Path | None:
        """Soubor tohohle stažení pod `downloads_dir` -- `rglob` místo pevné
        cesty, slskd strukturu zplošťuje po svém. Jen soubory změněné od
        začátku stažení (ne stejnojmenný pozůstatek z dřívějška), přednost má
        složka pojmenovaná jako vzdálená. slskd při kolizi přidá `_<ticks>`."""
        stem, dot, ext = basename.rpartition(".")
        # Jméno souboru od cizího člověka -- "[", "*", "?" by glob bral jako vzor.
        patterns = [glob.escape(basename)]
        if dot:
            patterns.append(glob.escape(stem) + "_*." + glob.escape(ext))
        candidates: list[tuple[Path, float]] = []
        for pattern in patterns:
            for path in self.downloads_dir.rglob(pattern):
                try:
                    mtime = path.stat().st_mtime
                except OSError:
                    continue
                if mtime >= since:
                    candidates.append((path, mtime))
        if not candidates:
            return None
        return max(candidates, key=lambda c: (bool(remote_dir) and c[0].parent.name == remote_dir, c[1]))[0]

    @staticmethod
    def _find_transfer(payload: dict, filename: str) -> dict | None:
        # `{"username": ..., "directories": [{"directory": ..., "files": [...]}]}`
        # -- hledá se podle jména, pořadí neodpovídá pořadí zafrontění. Při
        # opakovaném stažení téhož souboru bere nejnovější záznam.
        match: dict | None = None
        for directory in payload.get("directories", []):
            for f in directory.get("files", []):
                if f.get("filename") == filename:
                    if match is None or str(f.get("requestedAt", "")) > str(match.get("requestedAt", "")):
                        match = f
        return match


def _ytdlp_proxy_opts() -> dict:
    """YouTube přes Mullvad: gluetunův HTTP proxy (jen uvnitř Docker sítě).
    Když tunel spadne, proxy nemá kudy ven a stahování selže -- nikdy
    nepropadne na přímé spojení z tvojí skutečné IP."""
    proxy = os.environ.get("YTDLP_PROXY")
    return {"proxy": proxy} if proxy else {}


_BOT_BLOCK_MARKERS = ("not a bot", "HTTP Error 403")
_VPN_ROTATION_KEY = "vpn:rotation"
_VPN_ROTATION_COOLDOWN_S = 300


def _is_bot_block(exc: BaseException) -> bool:
    return any(marker in str(exc) for marker in _BOT_BLOCK_MARKERS)


async def _rotate_vpn_server() -> None:
    """YouTube blokuje jednotlivé Mullvad IP (živě ověřeno: jeden pražský
    server "Sign in to confirm you're not a bot", jiný ze stejného /24 v
    pořádku) -- místo návratu na skutečnou IP přepne gluetun na jiný náhodný
    server z `SERVER_CITIES`. Redis zámek: přepíná jen jeden worker naráz a
    nejvýš jednou za 5 minut, ostatní jen počkají na nové spojení."""
    url = os.environ.get("GLUETUN_CONTROL_URL")
    key = os.environ.get("GLUETUN_CONTROL_API_KEY")
    if not (url and key and os.environ.get("YTDLP_PROXY")):
        return
    from app.redis_bus import get_redis

    if not await get_redis().set(_VPN_ROTATION_KEY, "1", nx=True, ex=_VPN_ROTATION_COOLDOWN_S):
        await asyncio.sleep(10)
        return
    logger.warning("YouTube blokuje aktuální VPN IP -- přepínám Mullvad server")
    async with httpx.AsyncClient(timeout=10, headers={"X-API-Key": key}) as client:

        async def public_ip() -> str | None:
            for _ in range(25):
                try:
                    ip = (await client.get(f"{url}/v1/publicip/ip")).json().get("public_ip")
                except (httpx.HTTPError, ValueError):
                    ip = None
                if ip:
                    return ip
                await asyncio.sleep(1)
            return None

        blocked_ip = await public_ip()
        # Gluetun vybírá server náhodně a občas se trefí do stejného --
        # opakujeme, dokud nedostaneme jinou výstupní IP.
        for _ in range(4):
            await client.put(f"{url}/v1/vpn/status", json={"status": "stopped"})
            await asyncio.sleep(1)
            await client.put(f"{url}/v1/vpn/status", json={"status": "running"})
            await asyncio.sleep(2)
            new_ip = await public_ip()
            if new_ip and new_ip != blocked_ip:
                logger.warning("VPN přepnuta: %s -> %s", blocked_ip, new_ip)
                return
        logger.warning("VPN: nepodařilo se získat jinou výstupní IP než %s", blocked_ip)


class YoutubeProvider:
    """Záložní/rychlý provider přes yt-dlp. Stahuje NATIVNÍ m4a (AAC, itag
    140) bez překódování -- ~3 s na skladbu místo ~5 s s převodem do MP3
    (živě změřeno), a bez druhé ztrátové generace. Jen když m4a není
    k dispozici, spadne na starý převod `bestaudio -> mp3`.

    `resolve()` je čisté textové vyhledávání (`ytsearch1:`) -- YouTube o MBID
    nic neví, takže po stažení `fetch()` dopíše MBID/interpreta/název do tagů.
    """

    def __init__(self, *, preferred_bitrate_kbps: int = 320) -> None:
        self.preferred_bitrate_kbps = preferred_bitrate_kbps

    async def resolve(self, track: TrackMetadata, *, interactive: bool = False) -> ProviderCandidate | None:
        query = track.search_query
        if not query:
            return None
        return ProviderCandidate(source_provider="youtube", source_ref=query, extra={"query": query})

    def _base_opts(self, outtmpl: str, progress_hook: Callable[[dict], None]) -> dict:
        # BEZ `extractor_args.player_client` -- dřívější natvrdo nastavené
        # ["android", "web"] s yt-dlp 2026.08 selhávalo ("Sign in to confirm
        # you're not a bot" / "Requested format is not available", živě
        # ověřeno), výchozí výběr klientů yt-dlp funguje za ~1.8 s.
        return {
            "outtmpl": outtmpl,
            "noplaylist": True,
            "default_search": "ytsearch1",
            "quiet": True,
            "no_warnings": True,
            "socket_timeout": 15,
            "retries": 2,
            # Vždy od začátku: zbytek .part z přerušeného pokusu (restart
            # workeru) dával "HTTP Error 416: Requested range not satisfiable".
            "continuedl": False,
            "progress_hooks": [progress_hook],
            **_ytdlp_proxy_opts(),
        }

    async def fetch(
        self,
        track: TrackMetadata,
        candidate: ProviderCandidate,
        dest_stem: Path,
        on_progress: ProgressCallback,
        on_file_located: OnFileLocated,
    ) -> FetchResult:
        import yt_dlp  # lazy -- potřeba jen když se tenhle provider opravdu použije

        query = candidate.extra["query"]
        dest_stem.parent.mkdir(parents=True, exist_ok=True)
        outtmpl = f"{dest_stem}.%(ext)s"
        loop = asyncio.get_running_loop()
        last_reported = -1

        def progress_hook(d: dict) -> None:
            if d.get("status") != "downloading":
                return
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            if not total:
                return
            nonlocal last_reported
            pct = int(d.get("downloaded_bytes", 0) / total * 95)
            if pct != last_reported:
                last_reported = pct
                asyncio.run_coroutine_threadsafe(on_progress(pct), loop)

        m4a_opts = {**self._base_opts(outtmpl, progress_hook), "format": "bestaudio[ext=m4a]"}
        mp3_opts = {
            **self._base_opts(outtmpl, progress_hook),
            "format": "bestaudio/best",
            # `final_ext` -- bez něj yt-dlp u audia už v mp4 kontejneru spočítá
            # stejnou zdrojovou i cílovou cestu a spadne na os.replace.
            "final_ext": "mp3",
            "postprocessors": [
                {
                    "key": "FFmpegExtractAudio",
                    "preferredcodec": "mp3",
                    "preferredquality": str(self.preferred_bitrate_kbps),
                }
            ],
        }

        def pick_video() -> str:
            """Explicitní `ytsearch5:` + výběr podle délky -- `default_search`
            u některých dotazů (diakritika/rozbité kódování) vůbec nehledal,
            a první výsledek býval hodinový mix (živě: 112 MB "2 Hour
            Mashups Mix" místo skladby). Ploché hledání trvá ~1 s."""
            search_opts = {"quiet": True, "no_warnings": True, "extract_flat": "in_playlist", "socket_timeout": 15}
            with yt_dlp.YoutubeDL({**search_opts, **_ytdlp_proxy_opts()}) as ydl:
                info = ydl.extract_info(f"ytsearch5:{query}", download=False)
            entries = [
                e
                for e in (info or {}).get("entries") or []
                if e and e.get("id") and f"youtube:{e['id']}" not in track.rejected_sources
            ]
            if not entries:
                raise RuntimeError(f"YouTube nic nenašel pro '{query}'")
            target = track.duration_ms / 1000 if track.duration_ms else None

            def acceptable(e: dict) -> bool:
                d = e.get("duration")
                if d is None:
                    return e.get("live_status") not in ("is_live", "is_upcoming")
                if target:
                    return abs(d - target) <= max(20.0, target * 0.15)
                return 30 <= d <= 15 * 60

            # Přednost videím, jejichž název obsahuje název skladby (dřív
            # vyhrál první výsledek s dobrou délkou -- občas úplně jiná
            # skladba stejného interpreta, viz kontrola Shazamem).
            wanted = _title_tokens(track.title)

            def title_hit(e: dict) -> bool:
                return bool(wanted) and wanted <= _title_tokens(e.get("title") or "")

            # Jiná verze (live, cover, remix...) jen když ji skladba sama nese
            # v názvu (živě: "Guns for Hands" se stáhla živá verze).
            asked = _normalize(track.title)

            def other_version(e: dict) -> bool:
                title = _normalize(e.get("title") or "")
                return any(m in title.split() and m not in asked.split() for m in _VERSION_MARKERS)

            # Přísně: celý název, slova verze, žádná jiná verze -- radši
            # "nemáme" než jiná píseň/verze (živě: "Trees (Ned's Version)"
            # se stáhlo jako ukulele Heathens).
            entries = [e for e in entries if _matches_title(track.title, e.get("title") or "", track.album_title)]
            if not entries:
                raise RuntimeError(f"YouTube nemá '{track.title}' v téhle verzi")
            ok = [e for e in entries if acceptable(e)]
            album_words = _title_tokens(track.album_title or "")

            def album_hit(e: dict) -> bool:
                return bool(album_words) and album_words <= _title_tokens(e.get("title") or "")

            ok.sort(key=lambda e: (0 if title_hit(e) else 1, 1 if other_version(e) else 0, 0 if album_hit(e) else 1))
            if track.skip_candidates and ok:
                ok = ok[track.skip_candidates % len(ok):] + ok[: track.skip_candidates % len(ok)]
            chosen = ok[0] if ok else None
            if chosen is None:
                # Nic délkou nesedí (katalog může mít jinou verzi) -- aspoň ne
                # mixy/streamy: nejkratší rozumný výsledek.
                sane = [e for e in entries if e.get("duration") and 30 <= e["duration"] <= 15 * 60]
                if not sane:
                    raise RuntimeError(f"YouTube: žádný výsledek pro '{query}' nemá délku skladby")
                chosen = sane[0]
            return f"https://www.youtube.com/watch?v={chosen['id']}"

        chosen_url: list[str] = []

        def run_download() -> tuple[Path, int | None]:
            url = f"https://www.youtube.com/watch?v={track.youtube_id}" if track.youtube_id else pick_video()
            chosen_url[:] = [url]
            try:
                try:
                    with yt_dlp.YoutubeDL(m4a_opts) as ydl:
                        info = ydl.extract_info(url, download=True)
                except yt_dlp.utils.DownloadError as exc:
                    # YouTube občas zablokuje stažení (403) -- hned jinými
                    # klienty, ne až v dalším kole fronty (živě: skladba
                    # zůstala "Ve frontě"). Natvrdo jen jako záloha, viz _base_opts.
                    if "403" not in str(exc):
                        raise
                    retry_opts = {**m4a_opts, "extractor_args": {"youtube": {"player_client": ["tv", "web_safari", "mweb"]}}}
                    with yt_dlp.YoutubeDL(retry_opts) as ydl:
                        info = ydl.extract_info(url, download=True)
                path = dest_stem.with_suffix(".m4a")
                if path.exists():
                    abr = (info or {}).get("abr")
                    return path, int(abr) if abr else None
            except yt_dlp.utils.DownloadError as exc:
                if "format is not available" not in str(exc):
                    raise
            with yt_dlp.YoutubeDL(mp3_opts) as ydl:
                ydl.download([url])
            return dest_stem.with_suffix(".mp3"), self.preferred_bitrate_kbps

        try:
            dest_path, bitrate = await asyncio.to_thread(run_download)
        except Exception as exc:  # noqa: BLE001 - jen bot-blok přes VPN zkoušíme znovu
            if not _is_bot_block(exc) or not os.environ.get("YTDLP_PROXY"):
                raise
            await _rotate_vpn_server()
            dest_path, bitrate = await asyncio.to_thread(run_download)
        if not dest_path.exists():
            raise RuntimeError(f"yt-dlp nevytvořil očekávaný soubor {dest_path}")

        await asyncio.to_thread(_tag_file, dest_path, mbid=track.mbid, title=track.title, artist=track.artist_name)
        await on_progress(100)

        return FetchResult(
            path=dest_path,
            format=dest_path.suffix.lstrip("."),
            source_provider="youtube",
            bitrate_kbps=bitrate,
            source_url=chosen_url[0] if chosen_url else None,
            source_key=f"youtube:{chosen_url[0].rsplit('=', 1)[-1]}" if chosen_url else None,
        )


def _tag_file(path: Path, *, mbid: str | None, title: str, artist: str | None) -> None:
    if path.suffix.lower() == ".m4a":
        _tag_m4a(path, mbid=mbid, title=title, artist=artist)
    else:
        _tag_mp3(path, mbid=mbid, title=title, artist=artist)


def _tag_m4a(path: Path, *, mbid: str | None, title: str, artist: str | None) -> None:
    from mutagen.mp4 import MP4, MP4FreeForm

    audio = MP4(path)
    audio["\xa9nam"] = [title]
    if artist:
        audio["\xa9ART"] = [artist]
    if mbid:
        audio["----:com.apple.iTunes:MusicBrainz Track Id"] = [MP4FreeForm(mbid.encode())]
    audio.save()


def _tag_mp3(path: Path, *, mbid: str | None, title: str, artist: str | None) -> None:
    """Dopíše katalogové metadata do staženého MP3 -- `EasyID3` pro
    title/artist, syrový `ID3`/`UFID` pro MBID (`EasyID3` nemá bez ruční
    registrace klíč pro MusicBrainz)."""
    from mutagen.easyid3 import EasyID3
    from mutagen.id3 import ID3, ID3NoHeaderError, TXXX, UFID

    try:
        easy = EasyID3(path)
    except ID3NoHeaderError:
        easy = EasyID3()
        easy.save(path)
        easy = EasyID3(path)
    easy["title"] = title
    if artist:
        easy["artist"] = artist
    easy.save(path)

    if mbid:
        id3 = ID3(path)
        id3.setall("UFID", [UFID(owner="http://musicbrainz.org", data=mbid.encode())])
        id3.setall(
            "TXXX:MusicBrainz Track Id",
            [TXXX(encoding=3, desc="MusicBrainz Track Id", text=[mbid])],
        )
        id3.save(path)


class SoundcloudProvider:
    """SoundCloud přes yt-dlp -- přesný odkaz (import, vzácné skladby), nebo
    poslední záloha hledáním, když Soulseek i YouTube selžou (dema, remixy,
    nevydané věci). Kvalita jen ~128 kbps MP3, proto až na konec. Skladby
    jen pro Go+ (30s ukázka, formát `*_preview`) se neberou."""

    async def resolve(self, track: TrackMetadata, *, interactive: bool = False) -> ProviderCandidate | None:
        query = track.search_query
        if not track.soundcloud_url and not query:
            return None
        return ProviderCandidate(source_provider="soundcloud", source_ref=track.soundcloud_url or query, extra={})

    async def fetch(
        self,
        track: TrackMetadata,
        candidate: ProviderCandidate,
        dest_stem: Path,
        on_progress: ProgressCallback,
        on_file_located: OnFileLocated,
    ) -> FetchResult:
        import yt_dlp

        dest_stem.parent.mkdir(parents=True, exist_ok=True)
        loop = asyncio.get_running_loop()

        def hook(d: dict) -> None:
            total = d.get("total_bytes") or d.get("total_bytes_estimate")
            if d.get("status") == "downloading" and total:
                asyncio.run_coroutine_threadsafe(on_progress(int(d.get("downloaded_bytes", 0) / total * 95)), loop)

        base = {
            "outtmpl": f"{dest_stem}.%(ext)s",
            "noplaylist": True,
            "quiet": True,
            "no_warnings": True,
            "socket_timeout": 20,
            "retries": 2,
            "continuedl": False,
            "progress_hooks": [hook],
            **_ytdlp_proxy_opts(),
        }

        def pick() -> str:
            if track.soundcloud_url:
                return track.soundcloud_url
            with yt_dlp.YoutubeDL({"quiet": True, "no_warnings": True, "extract_flat": "in_playlist", **_ytdlp_proxy_opts()}) as ydl:
                info = ydl.extract_info(f"scsearch8:{candidate.source_ref}", download=False) or {}
            wanted = _title_tokens(track.title)
            target = track.duration_ms / 1000 if track.duration_ms else None
            asked = _normalize(track.title)
            for e in info.get("entries") or []:
                if not e or not e.get("url"):
                    continue
                d = e.get("duration")
                if d is not None and d <= 31:
                    continue  # Go+ ukázka
                if target and d and abs(d - target) > max(20.0, target * 0.15):
                    continue
                if not _matches_title(track.title, e.get("title") or "", track.album_title):
                    continue
                if f"soundcloud:{e['url']}" in track.rejected_sources:
                    continue
                return e["url"]
            raise RuntimeError(f"SoundCloud nic vhodného pro '{candidate.source_ref}'")

        chosen: list[str] = []

        def run() -> Path:
            url = pick()
            chosen[:] = [url]
            # Napřed přímo MP3 (bez překódování), jinak cokoli -> M4A (AAC).
            try:
                with yt_dlp.YoutubeDL({**base, "format": "bestaudio[ext=mp3][format_id!*=preview]"}) as ydl:
                    ydl.extract_info(url, download=True)
                if dest_stem.with_suffix(".mp3").exists():
                    return dest_stem.with_suffix(".mp3")
            except yt_dlp.utils.DownloadError as exc:
                if "format is not available" not in str(exc):
                    raise
            opts = {
                **base,
                "format": "bestaudio[format_id!*=preview]",
                "final_ext": "m4a",
                "postprocessors": [{"key": "FFmpegExtractAudio", "preferredcodec": "m4a"}],
            }
            with yt_dlp.YoutubeDL(opts) as ydl:
                ydl.extract_info(url, download=True)
            return dest_stem.with_suffix(".m4a")

        path = await asyncio.to_thread(run)
        if not path.exists():
            raise RuntimeError(f"yt-dlp (SoundCloud) nevytvořil {path}")
        await asyncio.to_thread(_tag_file, path, mbid=track.mbid, title=track.title, artist=track.artist_name)
        await on_progress(100)
        return FetchResult(
            path=path,
            format=path.suffix.lstrip("."),
            source_provider="soundcloud",
            bitrate_kbps=128 if path.suffix == ".mp3" else None,
            source_url=chosen[0] if chosen else None,
            source_key=f"soundcloud:{chosen[0]}" if chosen else None,
        )


class CompositeProvider:
    """Zkouší providery v zadaném pořadí. `resolve()` vrátí první nabídku,
    kterou nějaký provider najde (a zapamatuje si, který to byl). `fetch()`
    zkusí toho providera; pokud selže výjimkou, padá na DALŠÍHO v pořadí
    (a pro něj si nejdřív zavolá jeho vlastní `resolve()`, protože candidate
    z jiného providera pro něj nedává smysl) -- to je "fallback i při
    selhání stahování", ne jen při prázdném hledání.
    """

    def __init__(self, providers: Sequence[MediaProvider]) -> None:
        if not providers:
            raise ValueError("CompositeProvider potřebuje aspoň jeden provider")
        self._providers = list(providers)

    @property
    def providers(self) -> list[MediaProvider]:
        return list(self._providers)

    async def resolve(self, track: TrackMetadata, *, interactive: bool = False) -> ProviderCandidate | None:
        for index, provider in enumerate(self._providers):
            try:
                candidate = await provider.resolve(track, interactive=interactive)
            except Exception:
                logger.exception(
                    "%s.resolve() selhal pro %s, zkouším dalšího providera",
                    type(provider).__name__,
                    track.recording_id,
                )
                continue
            if candidate is not None:
                candidate.extra["_provider_index"] = index
                return candidate
        return None

    async def fetch(
        self,
        track: TrackMetadata,
        candidate: ProviderCandidate,
        dest_stem: Path,
        on_progress: ProgressCallback,
        on_file_located: OnFileLocated,
    ) -> FetchResult:
        start_index = candidate.extra.get("_provider_index", 0)
        last_error: Exception | None = None
        for index in range(start_index, len(self._providers)):
            provider = self._providers[index]
            try:
                current = (
                    candidate
                    if index == start_index
                    else await provider.resolve(track, interactive=bool(candidate.extra.get("interactive")))
                )
                if current is None:
                    continue
                return await provider.fetch(track, current, dest_stem, on_progress, on_file_located)
            except Exception as exc:
                last_error = exc
                logger.exception(
                    "%s.fetch() selhal pro %s, zkouším dalšího providera v pořadí",
                    type(provider).__name__,
                    track.recording_id,
                )
                continue
        raise last_error or RuntimeError(f"žádný provider nedokázal stáhnout zdroj pro {track.recording_id}")


def build_provider() -> MediaProvider:
    """`MEDIA_PROVIDER` env: `composite` (výchozí, slskd -> youtube fallback),
    `slskd`, `youtube`, nebo `placeholder` pro dev bez závislosti na obojím."""
    kind = os.environ.get("MEDIA_PROVIDER", "composite").lower()
    if kind == "placeholder":
        return PlaceholderProvider()
    if kind == "slskd":
        return SlskdProvider()
    if kind == "youtube":
        return YoutubeProvider()
    return CompositeProvider([SlskdProvider(), YoutubeProvider()])
