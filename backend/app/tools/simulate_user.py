"""Simulace uživatele přes API: projde běžné cesty v appce a zapíše chyby,
prázdné výsledky a pomalé odpovědi. Jen na TESTOVACÍM profilu (žádné
poslechy) -- skutečné profily odmítne. Nic nepřehrává (žádné stahování),
nic nemaže kromě vlastního zkušebního playlistu.

    python -m app.tools.simulate_user <user_id> [persona]

persona: newcomer (výchozí) | dad | power
"""

from __future__ import annotations

import json
import sys
import time
from typing import Any

import httpx
from sqlmodel import Session, func, select

from app.db import engine
from app.models import Listen

BASE = "http://localhost:8000/api/v1"
SLOW_MS = 3000

QUERIES = {
    "newcomer": ["twenty one pilots", "Beatles Abbey Road", "lo-fi", "Billie Eilish", "xqzvw nesmysl"],
    "dad": ["Tony Rice", "Kontrast", "bluegrass", "Jiří Stivín", "Žlutý pes", "Peter Rowan Old Home Place", "Druhá tráva"],
    "power": ["Nirvana 1993 live", "Kingdom Come Deliverance soundtrack", "Tame Impala Currents deluxe",
              "feat. Willie Nelson", "Sweet Melinda", "Bob Dylan Blood on the Tracks", "Mňága a Žďorp"],
}


class Sim:
    def __init__(self, token: str) -> None:
        self.client = httpx.Client(base_url=BASE, headers={"Authorization": f"Bearer {token}"}, timeout=60.0)
        self.steps: list[dict[str, Any]] = []

    def call(self, method: str, path: str, note: str = "", **kw) -> Any:
        t = time.monotonic()
        try:
            r = self.client.request(method, path, **kw)
            ms = int((time.monotonic() - t) * 1000)
            body = r.json() if "json" in r.headers.get("content-type", "") else None
            step = {"step": note or path, "method": method, "path": path, "status": r.status_code, "ms": ms}
            if r.status_code >= 400:
                step["problem"] = f"HTTP {r.status_code}: {str(body)[:200]}"
            elif ms > SLOW_MS:
                step["problem"] = f"pomalé ({ms} ms)"
            self.steps.append(step)
            return body
        except Exception as exc:  # noqa: BLE001
            self.steps.append({"step": note or path, "method": method, "path": path, "problem": f"výjimka {type(exc).__name__}: {exc}"})
            return None

    def flag(self, note: str, problem: str) -> None:
        self.steps.append({"step": note, "problem": problem})


def _issue_token(user_id: str) -> str:
    from app.routes.auth import _issue_token as issue

    with Session(engine) as s:
        return issue(s, user_id, "simulace uživatele")


def _first(items: Any, key: str = "id") -> str | None:
    if isinstance(items, list) and items and isinstance(items[0], dict):
        return items[0].get(key)
    return None


def _write_journeys(sim: Sim) -> None:
    """Zápisy, které nic nestahují: playlist (pořadí výběru!), Na později,
    oblíbený interpret, "nelíbí se" a jeho zrušení. Po sobě uklidí."""
    res = sim.call("GET", "/catalog/search", "Hledat pro playlist", params={"q": "Tony Rice Church Street Blues"}) or {}
    recs = [r["id"] for r in res.get("results") or [] if r.get("entityType") == "recording"][:3]
    found_artists = sim.call("GET", "/catalog/search", "Hledat interpreta", params={"q": "Tony Rice"}) or {}
    artists = [r["id"] for r in found_artists.get("results") or [] if r.get("entityType") == "artist"][:1]
    pl = sim.call("POST", "/playlists", "Nový playlist", json={"title": "Simulace – smazat"})
    pid = (pl or {}).get("id")
    if pid and len(recs) >= 2:
        # Přidávat v pořadí výběru -- v playlistu má být stejné pořadí.
        for rid in recs:
            sim.call("POST", f"/playlists/{pid}/items", "Přidat do playlistu", json={"recording_id": rid})
        detail = sim.call("GET", f"/playlists/{pid}", "Otevřít playlist") or {}
        items = detail.get("items") or detail.get("tracks") or []
        got = [(i.get("recordingId") or i.get("id") or (i.get("recording") or {}).get("id")) for i in items]
        if got and got != recs:
            sim.flag("Playlist", f"pořadí po přidání nesedí: {got} vs {recs}")
        sim.call("PATCH", f"/playlists/{pid}/items/reorder", "Přeskládat", json={"recording_ids": list(reversed(recs))})
        sim.call("PATCH", f"/playlists/{pid}", "Přejmenovat", json={"title": "Simulace 2"})
        sim.call("DELETE", f"/playlists/{pid}/items/{recs[0]}", "Odebrat z playlistu")
        # Ten samý dvakrát -- chybová cesta.
        again = sim.call("POST", f"/playlists/{pid}/items", "Přidat podruhé tutéž", json={"recording_id": recs[1]})
        del again
    if pid:
        sim.call("DELETE", f"/playlists/{pid}", "Smazat zkušební playlist")
        if sim.client.get(f"/playlists/{pid}").status_code != 404:
            sim.flag("Playlist", "smazaný playlist jde pořád otevřít")
    if recs:
        later = sim.call("POST", "/listen-later", "Na později", json={"kind": "track", "targetId": recs[0]}) or {}
        lid = later.get("id")
        if lid:
            sim.call("DELETE", f"/listen-later/{lid}", "Odebrat z Na později")
    if artists:
        aid = artists[0]
        sim.call("POST", f"/library/favorite-artists/{aid}", "Oblíbený interpret")
        sim.call("POST", f"/library/disliked-artists/{aid}", "Nelíbí se mi (interpret)")
        favs = sim.call("GET", "/library/favorite-artists", "Oblíbení po nelíbí se") or []
        if any((f.get("id") if isinstance(f, dict) else f) == aid for f in (favs if isinstance(favs, list) else favs.get("artists", []))):
            sim.flag("Nelíbí se", "interpret zůstal v oblíbených")
        sim.call("DELETE", f"/library/disliked-artists/{aid}", "Zpět: zrušit nelíbí se")
        sim.call("DELETE", f"/library/favorite-artists/{aid}", "Úklid oblíbeného")
        left = sim.call("GET", "/library/disliked-artists", "Kontrola po Zpět") or {}
        if aid in (left.get("artistIds") or []):
            sim.flag("Nelíbí se", "Zpět interpreta nevrátil")


def run(user_id: str, persona: str) -> dict[str, Any]:
    with Session(engine) as s:
        listens = s.exec(select(func.count()).select_from(Listen).where(Listen.user_id == user_id)).one()
    if listens:
        raise SystemExit("Profil má poslechy -- simulace jen na testovacím profilu.")
    sim = Sim(_issue_token(user_id))

    home = sim.call("GET", "/home", "Domů")
    sections = [sec.get("id") for sec in (home or {}).get("sections") or []]
    for bad in ("charts", "new_releases", "czech"):
        if persona == "newcomer" and bad in sections:
            sim.flag("Domů nováčka", f"sekce {bad} je vidět, má být výchozí vypnutá")
    real = [sec for sec in (home or {}).get("sections") or [] if sec.get("id") != "continue" and sec.get("items")]
    if not real:
        sim.flag("Domů", "prázdný Domů (nováček) – appka má ukázat prázdný stav s radou")
    sim.call("GET", "/home/layout", "Upravit Domů")
    sim.call("GET", "/home/recent", "Pokračovat v poslechu")
    chunk = sim.call("POST", "/home/play-now", "Pusť teď bez historie", json={"size": 8})
    if chunk is not None and not (chunk.get("tracks")):
        sim.flag("Pusť teď", "bez historie nevrátí nic – appka by měla nabídnout jinou cestu (Hledat)")

    for q in QUERIES.get(persona, QUERIES["newcomer"]):
        res = sim.call("GET", "/catalog/search", f"Hledat „{q}“", params={"q": q})
        if res is None:
            continue
        results = res.get("results") or []
        if not results and "nesmysl" not in q:
            sim.flag(f"Hledat „{q}“", "žádné výsledky")
        by_type: dict[str, list[dict]] = {}
        for item in results:
            by_type.setdefault(item.get("entityType") or "?", []).append(item)
        artist_id = _first(by_type.get("artist"))
        release_id = _first(by_type.get("release"))
        # Relevance: první výsledek má obsahovat aspoň jedno slovo dotazu.
        if results:
            from app.download_match import tokens

            top = results[0]
            label = " ".join(str(top.get(k) or "") for k in ("name", "title", "artistName"))
            if not set(tokens(q)) & set(tokens(label)) and "nesmysl" not in q:
                sim.flag(f"Hledat „{q}“", f"první výsledek nesouvisí: {label[:80]!r}")
        if artist_id:
            sim.call("GET", f"/catalog/artists/{artist_id}", f"Interpret z „{q}“")
            disco = sim.call("GET", f"/catalog/artists/{artist_id}/discography", "Diskografie")
            top = sim.call("GET", f"/catalog/artists/{artist_id}/top-tracks", "Top skladby")
            sim.call("GET", f"/catalog/artists/{artist_id}/bio", "Bio")
            if isinstance(top, list) and not top:
                sim.flag(f"Interpret z „{q}“", "žádné top skladby")
            if isinstance(disco, dict) and not disco.get("releases"):
                sim.flag(f"Interpret z „{q}“", "prázdná diskografie")
        if release_id:
            sim.call("GET", f"/catalog/releases/{release_id}", f"Album z „{q}“")
            tracks = sim.call("GET", f"/catalog/releases/{release_id}/tracks", "Skladby alba")
            sim.call("GET", f"/catalog/releases/{release_id}/credits", "Obsazení alba")
            if isinstance(tracks, list):
                if not tracks:
                    sim.flag(f"Album z „{q}“", "album bez skladeb")
                ids = [t.get("id") for t in tracks]
                if len(ids) != len(set(ids)):
                    sim.flag(f"Album z „{q}“", "stejná skladba v tracklistu víckrát")
                rid = _first(tracks)
                if rid:
                    sim.call("GET", f"/lyrics/{rid}", "Text skladby")
                    sim.call("GET", f"/share/recordings/{rid}", "Sdílet skladbu")

    sim.call("GET", "/browse", "Procházet")
    for cat in ("bluegrass", "folk", "rock"):
        sim.call("GET", f"/browse/{cat}", f"Žánr {cat}")
    sim.call("GET", "/games", "Herní soundtracky")
    sim.call("GET", "/movies", "Filmy a seriály")
    for path, note in (("/library/local-tracks", "Knihovna skladby"), ("/library/local-albums", "Knihovna alba"),
                       ("/library/local-artists", "Knihovna interpreti"), ("/library/liked-songs", "Oblíbené"),
                       ("/playlists", "Playlisty"), ("/listen-later", "Na později"), ("/library/history-imports", "Importy")):
        sim.call("GET", path, note)

    _write_journeys(sim)

    sim.client.close()
    # Klíč simulace hned zrušit (nezůstávají viset zařízení navíc).
    from sqlmodel import delete

    from app.models import AuthToken

    with Session(engine) as s:
        s.exec(delete(AuthToken).where(AuthToken.user_id == user_id, AuthToken.label == "simulace uživatele"))
        s.commit()
    problems = [s for s in sim.steps if s.get("problem")]
    slow = sorted((s for s in sim.steps if s.get("ms")), key=lambda s: -s["ms"])[:5]
    return {"user": user_id, "persona": persona, "steps": len(sim.steps), "problems": problems,
            "slowest": [{"step": s["step"], "ms": s["ms"]} for s in slow],
            "journey": [f"{s['step']} {s.get('status', '')}".strip() for s in sim.steps]}


def main() -> None:
    user_id = sys.argv[1]
    persona = sys.argv[2] if len(sys.argv) > 2 else "newcomer"
    print(json.dumps(run(user_id, persona), ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
