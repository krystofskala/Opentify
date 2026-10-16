"""Sdílený stream ("Teď streamuje", poslouchej se mnou) nad Opentify Connect.

Návrh: jojojo/claude/prace/opentify-noc/7y-sync-navrh.md (v3). Server je jen
pošťák s razítkem -- přehrávání posluchače řídí poslední kotva vysílače
(skladba, pozice P v serverovém čase T, rychlost, hraje), nic nepočítá.

Vysílač (WS i HTTP stejný tvar zprávy):
  - `broadcast.start {sid, bid, visibility, invited[], queue, anchor}`,
  - `broadcast.state {sid, bid, bseq, anchor?, queue?}`,
  - `broadcast.stop {sid, bid}`.
Posluchač:
  - `broadcast.join {sid, prepMs}`, `broadcast.leave {sid}`,
    `broadcast.sync {sid}` (pošli znovu frontu i kotvu), `broadcast.prep {prepMs}`.
Server -> posluchač: `broadcast.state {sid, clockId, gen, seq, anchor, queue?,
receivedServerMs}`, `broadcast.pending`, `broadcast.ended {reason}`.
Server -> vysílač: `broadcast.listeners {count, prepMs}`, `broadcast.taken`.

Ready bariéra (Kryštof 16. 10., rešerše 7y-reserse-synchronni-poslech.md):
start nové skladby po přeskoku, seek a play po pauze jdou přes
  - vysílač `broadcast.prepare {sid, bid, bseq, kind, anchor, queue?}` ->
    server založí epochu a pošle všem `broadcast.prepare {epoch, anchor}`,
    vysílači `broadcast.prepared {epoch}`,
  - každý (i vysílač) načte, předbufferuje na pozici a pošle
    `broadcast.ready {sid, epoch, rtt}`,
  - po všech ready, nejpozději po limitu (start 4 s, seek / play 1,5 s),
    server pošle `broadcast.go {epoch, atServerMs: T, anchor}` s
    T = teď + max(500 ms, 1,5 × nejvyšší RTT) + 300 ms; kdo nestihl, je
    `lagging` a dožene se sám.
Dohánění jednoho (pozdní příchozí, lagging, po bufferingu, po pozadí) je
připravený start pro jednoho: posluchač ztichne, zaparkuje na pozici a pošle
`broadcast.ready {sid, solo: true, recordingId, index, positionMs, rtt}`;
server mu sám pošle `broadcast.go {solo: true, atServerMs: T, positionMs}`.
`broadcast.suspend {sid, reason}`: posluchač bufferuje -- skupinu nezastavuje.
Pauza bariéru nemá (levná, okamžitá).

Organizátor (Kryštof 16. 10.): přeskakuje, mění pořadí a odebírá JEN vysílač.
Posluchač smí jen přidat skladbu: `broadcast.add {sid, item}` -> server ji
předá vysílači (`broadcast.added {addId, item, by}`), ten ji zařadí za
poslední přidanou od posluchačů a pošle frontu (položka nese `by`, `byId`,
`addId`). Nejvýš 10 čekajících přidaných na posluchače, 1 přidání za 2 s.
Server -> všem přihlášeným: `broadcasts.update {items}` (jen viditelná).

Pořadí (`clockId`, `gen`, `seq`) přiděluje server: vysílač po restartu appky
nebo převzetí začíná svůj `bseq` znovu od nuly a posluchači by jeho zprávy
jinak zahazovali jako staré (recenze K3, N1). `clockId` se mění s restartem
procesu -- posluchač pak srovnání vynuluje.

Rozesílání posluchačům je sloučené (nejvýš 1 zpráva za 200 ms na vysílání),
ale vždy s NEJNOVĚJŠÍM stavem: nic se nezahazuje (K2). Fronta jde
posluchači, kdykoli se liší od té, kterou mu server poslal naposled (N4).

Stav jen v paměti procesu -- předpokládá JEDEN worker uvicornu (jako Connect).
"""

from __future__ import annotations

import asyncio
import json
import logging
import re
import time
import uuid
from dataclasses import dataclass, field
from typing import Any, Callable, Iterable

logger = logging.getLogger("uvicorn.error.connect")

# Id procesu pro hodiny: po restartu API se mění a klient zahodí naměřený
# posun i srovnání pořadí (čas serveru je monotónní, ne "na zdi").
CLOCK_ID = uuid.uuid4().hex[:16]


def now_ms() -> float:
    return time.monotonic() * 1000.0


# Vysílač bez kontaktu (WS ani HTTP) tak dlouho, zatímco hraje = pryč.
OFFLINE_S = 90.0
# Nehraje (pauza, konec fronty) tak dlouho = vysílání končí. Platí i pro
# ticho pozastaveného vysílače (iOS appku po pauze na pozadí uspí, N2).
IDLE_S = 30 * 60.0
# Posluchač čekající na neznámé vysílání (restart API) -- pak `ended`.
PENDING_S = 60.0
# HTTP posluchač (long-poll z pozadí) bez dotazu tak dlouho = odešel.
HTTP_LISTENER_S = 60.0
# Skončená vysílání si pamatovat kvůli posluchačům, kteří se ptají přes HTTP.
ENDED_KEEP_S = 10 * 60.0
FLUSH_INTERVAL_S = 0.2
MAX_QUEUE = 500
MAX_INVITED = 50
MAX_POLLS_PER_USER = 4
# Čekající posluchači (neznámé vysílání po restartu API) -- strop, ať nejde
# paměť zaplnit náhodnými sid.
MAX_PENDING = 500
MAX_PENDING_PER_SID = 50
SEND_TIMEOUT_S = 5.0
# Položka fronty: jen pole snímku přehrávače (`_infoToJson`) + čitelná pro seznam.
_ITEM_FIELDS = ("id", "t", "a", "ai", "r", "art", "g", "gl", "d", "recordingId", "title", "artistName", "artworkUrl",
                "by", "byId", "addId")
MAX_ADDS_PER_LISTENER = 10
ADD_GAP_S = 2.0
PREP_MAX_MS = 1200
BARRIER_LIMIT_S = {"start": 4.0, "seek": 1.5}
# Vysílač, který se ani tak dlouho nenačte -- bariéra se zruší (zůstane pauza).
BARRIER_OWNER_LIMIT_S = 15.0
GO_MIN_LEAD_MS = 500.0
GO_RESERVE_MS = 300.0
DEFAULT_RTT_MS = 100.0


def go_lead_ms(rtts: Iterable[float], start_leads: Iterable[float] = ()) -> float:
    """Předstih `go`: aspoň 500 ms, 1,5 × nejpomalejší RTT a nejdelší naučený
    rozjezd člena (play() -> zvuk, Kryštof 16. 10.: "o ten čas si to načte
    dopředu"); + rezerva."""
    worst = max((r for r in rtts if r and r > 0), default=DEFAULT_RTT_MS)
    slowest_start = max((x for x in start_leads if x and x > 0), default=0.0)
    return max(GO_MIN_LEAD_MS, 1.5 * min(worst, 5000.0), min(slowest_start, 3000.0) + 200.0) + GO_RESERVE_MS


def solo_go(anchor: dict[str, Any], now_ms: float, parked_ms: float, rtt_ms: float, start_lead_ms: float = 0.0) -> tuple[float, float]:
    """Připravený start jednoho posluchače: (T, pozice). Posluchač zaparkoval
    na `parked_ms`; když tam vysílač dojde dost pozdě, začne se přesně tam
    (bez seeku), jinak nejbližší možný čas a pozice v něm."""
    rate = float(anchor.get("rate") or 1.0)
    p0 = float(anchor.get("positionMs") or 0.0)
    t0 = float(anchor.get("atServerMs") or now_ms)
    start = anchor.get("startAtServerMs")
    if isinstance(start, (int, float)) and t0 <= start + 1:
        t0 = float(start)
    earliest = now_ms + go_lead_ms([rtt_ms], [start_lead_ms])
    t_park = t0 + (parked_ms - p0) / rate
    if earliest <= t_park <= earliest + 3000:
        return t_park, parked_ms
    return earliest, p0 + (earliest - t0) * rate

_ID_RE = re.compile(r"^[A-Za-z0-9_-]{16,64}$")

_ANCHOR_NUM = ("index", "qv", "epoch", "positionMs", "atServerMs", "rate", "durationMs", "startAtServerMs", "transitionAtServerMs")
_ANCHOR_STR = ("recordingId", "repeatMode")


def valid_id(value: Any) -> bool:
    return isinstance(value, str) and bool(_ID_RE.match(value))


def clean_anchor(raw: Any) -> dict[str, Any] | None:
    """Jen známá pole se správným typem -- zbytek se zahodí."""
    if not isinstance(raw, dict):
        return None
    out: dict[str, Any] = {}
    for k in _ANCHOR_NUM:
        v = raw.get(k)
        if isinstance(v, (int, float)) and not isinstance(v, bool):
            out[k] = v
    for k in _ANCHOR_STR:
        v = raw.get(k)
        if isinstance(v, str):
            out[k] = v[:128]
    out["isPlaying"] = bool(raw.get("isPlaying"))
    out["clockOk"] = raw.get("clockOk") is not False
    # Bez hodin žádný plán (N7) -- posluchač by startoval podle špatného času.
    if not out["clockOk"]:
        out.pop("startAtServerMs", None)
        out.pop("transitionAtServerMs", None)
    if not out.get("recordingId"):
        return None
    return out


def clean_queue(raw: Any) -> dict[str, Any] | None:
    if not isinstance(raw, dict) or not isinstance(raw.get("items"), list):
        return None
    items = []
    for i in raw["items"][:MAX_QUEUE]:
        if not isinstance(i, dict) or not isinstance(i.get("recordingId"), str):
            continue
        item = {}
        for k in _ITEM_FIELDS:
            v = i.get(k)
            if isinstance(v, str):
                item[k] = v[:1000]
            elif isinstance(v, (int, float)) and not isinstance(v, bool):
                item[k] = v
        items.append(item)
    qv = raw.get("qv")
    base = raw.get("baseIndex")
    return {
        "qv": qv if isinstance(qv, int) and not isinstance(qv, bool) else 0,
        "baseIndex": base if isinstance(base, int) and not isinstance(base, bool) else 0,
        "items": items,
    }


def summary_track(anchor: dict[str, Any] | None, queue: dict[str, Any] | None) -> dict[str, Any] | None:
    """Karta do seznamu: název / interpret / obal aktuální skladby z fronty."""
    if not anchor:
        return None
    rid = anchor.get("recordingId")
    item = None
    if queue:
        idx = anchor.get("index")
        if isinstance(idx, int):
            i = idx - queue.get("baseIndex", 0)
            if 0 <= i < len(queue["items"]) and queue["items"][i].get("recordingId") == rid:
                item = queue["items"][i]
        if item is None:
            item = next((x for x in queue["items"] if x.get("recordingId") == rid), None)
    item = item or {}

    def s(key: str) -> str | None:
        v = item.get(key)
        return v[:300] if isinstance(v, str) else None

    return {
        "recordingId": rid,
        "title": s("title"),
        "artist": s("artistName") or s("artist"),
        "artworkUrl": s("artworkUrl"),
    }


@dataclass
class _Listener:
    user_id: str
    device_id: str | None
    ws: Any = None  # WebSocket, nebo None u HTTP posluchače
    last_seen: float = 0.0
    prep_ms: int | None = None
    healthy: bool = True
    sent_qv: int | None = None
    sent_gen: int | None = None
    # Bariéra: nestihl limit (dožene se sám), bufferuje / je na pozadí.
    lagging: bool = False
    suspended: bool = False
    rtt_ms: float | None = None
    start_lead_ms: float | None = None
    last_add: float = -1e18


@dataclass
class Room:
    sid: str
    owner_id: str
    owner_name: str
    device_id: str | None
    bid: str
    visibility: str
    invited: set[str]
    gen: int = 1
    seq: int = 0
    bseq: int = -1
    anchor: dict[str, Any] | None = None
    queue: dict[str, Any] | None = None
    owner_ws: Any = None
    last_contact: float = 0.0
    last_playing: float = 0.0
    received_ms: float = 0.0
    listeners: dict[Any, _Listener] = field(default_factory=dict)
    last_flush: float = -1e18
    flush_task: asyncio.Task | None = None
    cond: asyncio.Condition | None = None
    last_summary: Any = None
    last_listener_info: Any = None
    barrier_epoch: int = 0
    # Přidané posluchači, které vysílač ještě nepotvrdil ve frontě.
    pending_adds: list[dict[str, Any]] = field(default_factory=list)
    add_seq: int = 0
    # {epoch, kind, anchor, deadline, required: set, ready: set, rtts: dict, owner_ready, created}
    barrier: dict[str, Any] | None = None


class BroadcastError(Exception):
    """Chyba požadavku vysílače: `status` jako HTTP (403 / 409 / 410)."""

    def __init__(self, status: int, detail: str) -> None:
        super().__init__(detail)
        self.status = status
        self.detail = detail


class BroadcastHub:
    def __init__(self, clock: Callable[[], float] = time.monotonic) -> None:
        self._clock = clock
        self.rooms: dict[str, Room] = {}
        self._ended: dict[str, tuple[str, float, str, str, set[str]]] = {}
        # sid -> čekající posluchači (WS), když vysílání ještě neexistuje.
        self._pending: dict[str, dict[Any, tuple[str, str | None, float]]] = {}
        self._pending_ws: dict[int, Any] = {}
        self._polls: dict[str, int] = {}
        # Kdo všechno je přihlášený (pro `broadcasts.update`) -- dodá realtime.
        self.connections: Callable[[], Iterable[tuple[str, Any]]] = lambda: ()
        self._sweeper: asyncio.Task | None = None

    # --- pomocné -----------------------------------------------------------

    def _now(self) -> float:
        return self._clock()

    def server_ms(self) -> float:
        return self._clock() * 1000.0

    @staticmethod
    def can_see(room_owner: str, visibility: str, invited: set[str], user_id: str) -> bool:
        return user_id == room_owner or visibility == "server" or user_id in invited

    def _visible(self, room: Room, user_id: str) -> bool:
        return self.can_see(room.owner_id, room.visibility, room.invited, user_id)

    def room_of_owner(self, user_id: str) -> Room | None:
        return next((r for r in self.rooms.values() if r.owner_id == user_id), None)

    async def _send(self, ws: Any, message: dict[str, Any]) -> bool:
        if ws is None:
            return False
        try:
            # Zaseknuté spojení (plný buffer) nesmí zdržet rozesílání ostatním.
            await asyncio.wait_for(ws.send_text(json.dumps(message)), timeout=SEND_TIMEOUT_S)
            return True
        except Exception:  # noqa: BLE001 -- spojení se mezitím zavřelo
            return False

    def is_listening(self, user_id: str, device_key: str | None) -> bool:
        """Zařízení teď poslouchá cizí vysílání -- jeho stav přehrávání není
        vlastní volba (záložní poslechy app/connect_listens.py ho přeskočí)."""
        if not device_key:
            return False
        for room in self.rooms.values():
            for key, lst in room.listeners.items():
                if lst.user_id == user_id and (lst.device_id == device_key or key == device_key):
                    return True
        return False

    # --- seznam ------------------------------------------------------------

    def listener_count(self, room: Room) -> int:
        now = self._now()
        seen: set[tuple[str, str]] = set()
        for key, lst in room.listeners.items():
            if lst.ws is None and now - lst.last_seen > HTTP_LISTENER_S:
                continue
            seen.add((lst.user_id, lst.device_id or str(key)))
        return len(seen)

    def visible_list(self, user_id: str) -> list[dict[str, Any]]:
        """Jen id, jméno vysílače, aktuální skladba a počet posluchačů --
        žádné id zařízení, `bid` ani seznam pozvaných."""
        out = []
        for room in self.rooms.values():
            if not self._visible(room, user_id) or room.anchor is None:
                continue
            out.append({
                "id": room.sid,
                "name": room.owner_name,
                "mine": room.owner_id == user_id,
                "isPlaying": bool(room.anchor.get("isPlaying")),
                "track": summary_track(room.anchor, room.queue),
                "listeners": self.listener_count(room),
            })
        return out

    async def _announce(self, force: bool = False) -> None:
        """`broadcasts.update` všem přihlášeným, když se změnilo, co by viděli."""
        if not force:
            changed = False
            for room in self.rooms.values():
                summary = (summary_track(room.anchor, room.queue), self.listener_count(room), bool(room.anchor and room.anchor.get("isPlaying")))
                if summary != room.last_summary:
                    room.last_summary = summary
                    changed = True
            if not changed:
                return
        for user_id, ws in list(self.connections()):
            await self._send(ws, {"type": "broadcasts.update", "payload": {"items": self.visible_list(user_id)}})

    async def _tell_owner(self, room: Room) -> None:
        """Vysílači: kolik má posluchačů a nejdelší přípravu (plánovaný start).
        Do přípravy jen zdraví posluchači -- pomalý by zdržel každý přeskok (N10)."""
        preps = [
            lst.prep_ms for lst in room.listeners.values()
            if lst.healthy and lst.ws is not None and isinstance(lst.prep_ms, int)
        ]
        info = {"count": self.listener_count(room), "prepMs": min(max(preps), PREP_MAX_MS) if preps else None}
        if info == room.last_listener_info:
            return
        room.last_listener_info = info
        await self._send(room.owner_ws, {"type": "broadcast.listeners", "payload": {"sid": room.sid, **info}})

    def listener_info(self, room: Room) -> dict[str, Any]:
        preps = [lst.prep_ms for lst in room.listeners.values() if lst.healthy and isinstance(lst.prep_ms, int)]
        return {"listeners": self.listener_count(room), "prepMs": min(max(preps), PREP_MAX_MS) if preps else None}

    # --- vysílač -----------------------------------------------------------

    async def start(
        self,
        owner_id: str,
        owner_name: str,
        device_id: str | None,
        payload: dict[str, Any],
        allowed_invites: set[str] | None,
        owner_ws: Any = None,
    ) -> Room:
        """Nové vysílání, převzetí (nový `bid`) nebo obnova po restartu API
        či 409 (stejné `sid`, viditelnost a fronta znovu)."""
        sid, bid = payload.get("sid"), payload.get("bid")
        if not valid_id(sid) or not valid_id(bid):
            raise BroadcastError(400, "Neplatné id vysílání.")
        anchor = clean_anchor(payload.get("anchor"))
        queue = clean_queue(payload.get("queue"))
        visibility = "server" if payload.get("visibility") == "server" else "invited"
        invited_raw = payload.get("invited") if isinstance(payload.get("invited"), list) else []
        invited = {str(u) for u in invited_raw[:MAX_INVITED] if isinstance(u, str)}
        if allowed_invites is not None:
            invited &= allowed_invites
        invited.discard(owner_id)
        now = self._now()
        room = self.rooms.get(sid)
        if room is not None and room.owner_id != owner_id:
            raise BroadcastError(403, "Tohle vysílání patří jinému profilu.")
        if sid in self._ended and room is None and self._ended[sid][2] != owner_id:
            raise BroadcastError(403, "Tohle vysílání patří jinému profilu.")
        # Jeden profil = jedno vysílání: starší jiné sid skončí.
        for other in list(self.rooms.values()):
            if other.owner_id == owner_id and other.sid != sid:
                await self._send(other.owner_ws, {"type": "broadcast.taken", "payload": {"sid": other.sid}})
                await self.end(other.sid, "replaced", announce=False)
        if room is None:
            room = Room(
                sid=sid, owner_id=owner_id, owner_name=owner_name, device_id=device_id, bid=bid,
                visibility=visibility, invited=invited, cond=asyncio.Condition(), last_playing=now,
            )
            self.rooms[sid] = room
            self._ended.pop(sid, None)
            logger.info("broadcast %s: start %s (%s, pozvaných %d)", sid[:8], owner_name, visibility, len(invited))
        else:
            if room.bid != bid:
                # Převzetí jiným zařízením / restart appky vysílače: nová generace,
                # staré zařízení končí.
                if room.owner_ws is not None and room.owner_ws is not owner_ws:
                    await self._send(room.owner_ws, {"type": "broadcast.taken", "payload": {"sid": sid}})
                room.gen += 1
                room.bid = bid
                room.bseq = -1
            room.visibility, room.invited, room.device_id = visibility, invited, device_id
            # Kdo už viditelnost nemá, odchází.
            for key, lst in list(room.listeners.items()):
                if not self._visible(room, lst.user_id):
                    room.listeners.pop(key, None)
                    await self._send(lst.ws, {"type": "broadcast.ended", "payload": {"sid": sid, "reason": "hidden"}})
        if owner_ws is not None:
            room.owner_ws = owner_ws
        room.last_contact = now
        bseq = payload.get("bseq")
        room.bseq = bseq if isinstance(bseq, int) and not isinstance(bseq, bool) else room.bseq
        if queue is not None:
            room.queue = queue
            self._ack_adds(room)
        if anchor is not None:
            self._set_anchor(room, anchor)
        room.seq += 1
        await self._attach_pending(room)
        await self._changed(room)
        self._ensure_sweeper()
        return room

    def _set_anchor(self, room: Room, anchor: dict[str, Any]) -> None:
        prev = room.anchor
        now_ms = self.server_ms()
        # Vysílač bez platných hodin posílá svůj vlastní (klientský) čas, který
        # se serverem nesouvisí -- přerazítkovat časem přijetí (chyba = jen
        # jednosměrná latence). Dřív se klientský čas posílal dál a posluchač
        # ho extrapoloval proti času serveru (test 16. 10.).
        if not anchor.get("clockOk", True):
            anchor["atServerMs"] = now_ms
        # Heartbeat bez plánu přechodu nesmí smazat plán téže skladby (N4).
        # Plán STARTU se nepřenáší: kotva bez něj je změřená po rozjezdu a
        # s ním by posluchač uběhlý čas započítal dvakrát.
        if prev and prev.get("recordingId") == anchor.get("recordingId") and prev.get("index") == anchor.get("index"):
            k = "transitionAtServerMs"
            if k not in anchor and k in prev and anchor.get("clockOk", True):
                anchor[k] = prev[k]
        room.anchor = anchor
        room.received_ms = now_ms
        if anchor.get("isPlaying"):
            room.last_playing = self._now()

    def _owned(self, owner_id: str, payload: dict[str, Any]) -> Room:
        sid, bid = payload.get("sid"), payload.get("bid")
        room = self.rooms.get(sid) if isinstance(sid, str) else None
        if room is None:
            if isinstance(sid, str) and sid in self._ended:
                raise BroadcastError(410, "Vysílání skončilo.")
            raise BroadcastError(409, "Vysílání server nezná – pošli celý start.")
        if room.owner_id != owner_id:
            raise BroadcastError(403, "Tohle vysílání patří jinému profilu.")
        if room.bid != bid:
            raise BroadcastError(410, "Vysílání převzalo jiné zařízení.")
        return room

    async def state(self, owner_id: str, payload: dict[str, Any], owner_ws: Any = None) -> Room:
        room = self._owned(owner_id, payload)
        room.last_contact = self._now()
        if owner_ws is not None:
            room.owner_ws = owner_ws
        bseq = payload.get("bseq")
        if not isinstance(bseq, int) or isinstance(bseq, bool):
            raise BroadcastError(400, "Chybí bseq.")
        if bseq <= room.bseq:
            # Zpožděná zpráva (HTTP vs. WS, opakované odeslání) -- novější stav
            # už máme. Jen udržení naživu.
            return room
        room.bseq = bseq
        queue = clean_queue(payload.get("queue"))
        anchor = clean_anchor(payload.get("anchor"))
        if queue is not None:
            room.queue = queue
            self._ack_adds(room)
        if anchor is not None:
            # Nový stav od vysílače (pauza, jiná skladba bez bariéry) ruší
            # rozběhnutou bariéru -- `go` by pustil něco, co už neplatí.
            room.barrier = None
            self._set_anchor(room, anchor)
        if queue is None and anchor is None:
            return room  # jen heartbeat
        room.seq += 1
        await self._changed(room)
        return room

    async def stop(self, owner_id: str, payload: dict[str, Any]) -> None:
        room = self._owned(owner_id, payload)
        await self.end(room.sid, "stopped")

    # --- ready bariéra -----------------------------------------------------

    async def prepare(self, owner_id: str, payload: dict[str, Any], owner_ws: Any = None) -> Room:
        """Vysílač ohlásil start / seek / play: všichni načtou a nahlásí ready."""
        room = self._owned(owner_id, payload)
        room.last_contact = self._now()
        if owner_ws is not None:
            room.owner_ws = owner_ws
        bseq = payload.get("bseq")
        if not isinstance(bseq, int) or isinstance(bseq, bool):
            raise BroadcastError(400, "Chybí bseq.")
        if bseq <= room.bseq:
            return room
        room.bseq = bseq
        anchor = clean_anchor(payload.get("anchor"))
        if anchor is None:
            raise BroadcastError(400, "Chybí kotva.")
        queue = clean_queue(payload.get("queue"))
        if queue is not None:
            room.queue = queue
            self._ack_adds(room)
        kind = "seek" if payload.get("kind") == "seek" else "start"
        # Do `go` stojí na pozici -- pozdní příchozí a HTTP posluchači vidí pauzu.
        anchor.pop("startAtServerMs", None)
        anchor.pop("transitionAtServerMs", None)
        self._set_anchor(room, {**anchor, "isPlaying": False})
        room.barrier_epoch += 1
        epoch = room.barrier_epoch
        now = self._now()
        room.barrier = {
            "epoch": epoch,
            "kind": kind,
            "anchor": anchor,
            "deadline": now + BARRIER_LIMIT_S[kind],
            "created": now,
            "required": {k for k, lst in room.listeners.items() if lst.ws is not None and not lst.suspended},
            "ready": set(),
            "rtts": {},
            "leads": {},
            "owner_ready": False,
        }
        room.seq += 1
        logger.info("broadcast %s: prepare %s #%d, čeká %d", room.sid[:8], kind, epoch, len(room.barrier["required"]))
        await self._send(room.owner_ws, {"type": "broadcast.prepared", "payload": {"sid": room.sid, "epoch": epoch}})
        for lst in list(room.listeners.values()):
            await self._send_prepare(room, lst)
        if room.cond is not None:
            async with room.cond:
                room.cond.notify_all()
        self._arm_barrier_timer(room, epoch, BARRIER_LIMIT_S[kind])
        await self._announce()
        return room

    async def _send_prepare(self, room: Room, lst: _Listener) -> None:
        b = room.barrier
        if b is None or lst.ws is None:
            return
        qv = room.queue.get("qv") if room.queue else None
        include_queue = lst.sent_qv != qv or lst.sent_gen != room.gen
        msg = {
            "sid": room.sid, "epoch": b["epoch"], "kind": b["kind"], "anchor": b["anchor"],
            "clockId": CLOCK_ID, "gen": room.gen, "seq": room.seq, "serverMs": self.server_ms(),
        }
        if include_queue:
            msg["queue"] = room.queue
        if await self._send(lst.ws, {"type": "broadcast.prepare", "payload": msg}):
            lst.sent_qv = qv
            lst.sent_gen = room.gen

    def _arm_barrier_timer(self, room: Room, epoch: int, delay: float) -> None:
        try:
            asyncio.get_running_loop().create_task(self._barrier_timer(room, epoch, delay))
        except RuntimeError:
            pass

    async def _barrier_timer(self, room: Room, epoch: int, delay: float) -> None:
        await asyncio.sleep(delay + 0.01)
        if self.rooms.get(room.sid) is room and room.barrier and room.barrier["epoch"] == epoch:
            await self.check_barrier(room)
            if room.barrier and room.barrier["epoch"] == epoch:
                # Čeká se už jen na vysílač -- zkusit znovu, nejdéle do zrušení.
                self._arm_barrier_timer(room, epoch, 0.5)

    async def ready(self, user_id: str, ws: Any, payload: dict[str, Any], owner: bool = False) -> None:
        """Člen je načtený a předbufferovaný na pozici bariéry (nebo zaparkovaný
        pro připravený start jednoho)."""
        sid = payload.get("sid")
        room = self.rooms.get(sid) if isinstance(sid, str) else None
        if room is None:
            return
        rtt = payload.get("rtt")
        rtt = float(rtt) if isinstance(rtt, (int, float)) and not isinstance(rtt, bool) else None
        lead = payload.get("startLeadMs")
        lead = float(lead) if isinstance(lead, (int, float)) and not isinstance(lead, bool) else None
        if owner or (room.owner_id == user_id and room.owner_ws is ws):
            b = room.barrier
            if b is not None and payload.get("epoch") == b["epoch"]:
                b["owner_ready"] = True
                if rtt is not None:
                    b["rtts"]["owner"] = rtt
                if lead is not None:
                    b["leads"]["owner"] = lead
                room.last_contact = self._now()
                await self.check_barrier(room)
            return
        lst = room.listeners.get(id(ws))
        if lst is None:
            return
        lst.last_seen = self._now()
        if rtt is not None:
            lst.rtt_ms = rtt
        if lead is not None:
            lst.start_lead_ms = lead
        if payload.get("solo"):
            await self._solo(room, lst, payload)
            return
        b = room.barrier
        if b is None or payload.get("epoch") != b["epoch"]:
            return  # stará epocha
        b["ready"].add(id(ws))
        if rtt is not None:
            b["rtts"][id(ws)] = rtt
        if lead is not None:
            b["leads"][id(ws)] = lead
        await self.check_barrier(room)

    async def check_barrier(self, room: Room) -> None:
        b = room.barrier
        if b is None:
            return
        now = self._now()
        if not b["owner_ready"]:
            if now - b["created"] > BARRIER_OWNER_LIMIT_S:
                logger.info("broadcast %s: bariéra #%d zrušena, vysílač se nenačetl", room.sid[:8], b["epoch"])
                room.barrier = None
            return
        # Kdo mezitím odešel nebo začal bufferovat, se nečeká.
        required = {k for k in b["required"] if k in room.listeners and not room.listeners[k].suspended}
        if not required <= b["ready"] and now < b["deadline"]:
            return
        await self._go(room)

    async def _go(self, room: Room) -> None:
        b = room.barrier
        assert b is not None
        room.barrier = None
        rtts = list(b["rtts"].values())
        t = self.server_ms() + go_lead_ms(rtts, b["leads"].values())
        anchor = {**b["anchor"], "atServerMs": t, "startAtServerMs": t, "isPlaying": True, "clockOk": True}
        self._set_anchor(room, anchor)
        room.last_playing = self._now()
        room.seq += 1
        lagging = 0
        for key, lst in room.listeners.items():
            if key in b["required"] and key not in b["ready"]:
                lst.lagging = True  # nestihl limit -- dožene se připraveným startem sám
                lagging += 1
            elif key in b["ready"]:
                lst.lagging = False
        logger.info("broadcast %s: go #%d za %.0f ms, ready %d, lagging %d", room.sid[:8], b["epoch"], t - self.server_ms(), len(b["ready"]), lagging)
        msg = {
            "sid": room.sid, "epoch": b["epoch"], "atServerMs": t, "anchor": anchor,
            "clockId": CLOCK_ID, "gen": room.gen, "seq": room.seq, "serverMs": self.server_ms(),
        }
        await self._send(room.owner_ws, {"type": "broadcast.go", "payload": msg})
        for lst in list(room.listeners.values()):
            await self._send(lst.ws, {"type": "broadcast.go", "payload": msg})
        room.last_flush = self._now()
        if room.cond is not None:
            async with room.cond:
                room.cond.notify_all()
        await self._announce()

    async def _solo(self, room: Room, lst: _Listener, payload: dict[str, Any]) -> None:
        """Připravený start pro jednoho (pozdní příchozí, lagging, po bufferingu)."""
        anchor = room.anchor
        if anchor is None or room.barrier is not None:
            return  # běží bariéra -- dostane společné `go`
        if payload.get("recordingId") != anchor.get("recordingId") or payload.get("index") != anchor.get("index"):
            # Zaparkoval na jiné skladbě -- pošli mu aktuální stav, zkusí znovu.
            await self._send_state(room, lst, reset=True)
            return
        parked = payload.get("positionMs")
        parked = float(parked) if isinstance(parked, (int, float)) and not isinstance(parked, bool) else 0.0
        now = self.server_ms()
        if anchor.get("isPlaying"):
            t, pos = solo_go(anchor, now, parked, lst.rtt_ms or DEFAULT_RTT_MS, lst.start_lead_ms or 0.0)
            playing = True
        else:
            t, pos, playing = now, float(anchor.get("positionMs") or 0.0), False
        lst.lagging = False
        lst.suspended = False
        await self._send(lst.ws, {"type": "broadcast.go", "payload": {
            "sid": room.sid, "solo": True, "atServerMs": t, "positionMs": pos, "isPlaying": playing,
            "recordingId": anchor.get("recordingId"), "index": anchor.get("index"),
            "clockId": CLOCK_ID, "gen": room.gen, "seq": room.seq, "serverMs": now,
        }})

    # --- přidávání posluchači (organizátor = vysílač) ----------------------

    def _ack_adds(self, room: Room) -> None:
        if not room.pending_adds or not room.queue:
            return
        seen = {i.get("addId") for i in room.queue["items"] if i.get("addId")}
        room.pending_adds = [a for a in room.pending_adds if a["addId"] not in seen]

    def _waiting_adds(self, room: Room, user_id: str) -> int:
        """Kolik přidaných od profilu ještě čeká (nepotvrzené + ve frontě před sebou)."""
        n = sum(1 for a in room.pending_adds if a["byId"] == user_id)
        if room.queue and room.anchor:
            idx = room.anchor.get("index")
            base = room.queue.get("baseIndex", 0)
            start = (idx - base + 1) if isinstance(idx, int) else 0
            n += sum(1 for i in room.queue["items"][max(0, start):] if i.get("byId") == user_id)
        return n

    async def add_item(self, user_id: str, ws: Any, payload: dict[str, Any]) -> str | None:
        """Posluchač přidává skladbu do fronty vysílání. Vrací důvod odmítnutí."""
        sid = payload.get("sid")
        room = self.rooms.get(sid) if isinstance(sid, str) else None
        lst = room.listeners.get(id(ws)) if room else None
        if room is None or lst is None or lst.user_id != user_id or not self._visible(room, user_id):
            return "Do tohohle vysílání nepřidáváš (nejsi připojený)."
        q = clean_queue({"items": [payload.get("item")]}) if isinstance(payload.get("item"), dict) else None
        if not q or not q["items"]:
            return "Neplatná skladba."
        now = self._now()
        if now - lst.last_add < ADD_GAP_S:
            return "Moc rychle – chvilku počkej."
        if self._waiting_adds(room, user_id) >= MAX_ADDS_PER_LISTENER:
            return f"Čeká už {MAX_ADDS_PER_LISTENER} tvých skladeb – počkej, až se zahrají."
        lst.last_add = now
        room.add_seq += 1
        name = await asyncio.to_thread(profile_name, user_id)
        item = {**q["items"][0], "by": name[:60], "byId": user_id, "addId": f"{room.add_seq}"}
        room.pending_adds.append({"addId": item["addId"], "byId": user_id, "item": item})
        logger.info("broadcast %s: %s přidal %s", room.sid[:8], name, item.get("title"))
        await self._send(room.owner_ws, {"type": "broadcast.added", "payload": {"sid": room.sid, "addId": item["addId"], "item": item, "by": item["by"]}})
        return None

    async def suspend(self, ws: Any, payload: dict[str, Any]) -> None:
        room = self.rooms.get(payload.get("sid")) if isinstance(payload.get("sid"), str) else None
        lst = room.listeners.get(id(ws)) if room else None
        if room is None or lst is None:
            return
        lst.suspended = True
        await self.check_barrier(room)

    async def end(self, sid: str, reason: str, announce: bool = True) -> None:
        room = self.rooms.pop(sid, None)
        if room is None:
            return
        logger.info("broadcast %s: konec (%s)", sid[:8], reason)
        self._ended[sid] = (reason, self._now(), room.owner_id, room.visibility, set(room.invited))
        if room.flush_task is not None:
            room.flush_task.cancel()
        for lst in list(room.listeners.values()):
            await self._send(lst.ws, {"type": "broadcast.ended", "payload": {"sid": sid, "reason": reason}})
        if room.cond is not None:
            async with room.cond:
                room.seq += 1
                room.cond.notify_all()
        if announce:
            await self._announce(force=True)

    # --- posluchač ---------------------------------------------------------

    async def join(self, user_id: str, device_id: str | None, ws: Any, payload: dict[str, Any]) -> None:
        sid = payload.get("sid")
        if not valid_id(sid):
            return
        prep = payload.get("prepMs")
        prep = int(prep) if isinstance(prep, (int, float)) and not isinstance(prep, bool) else None
        room = self.rooms.get(sid)
        if room is None:
            ended = self._ended.get(sid)
            if ended is not None:
                reason, _at, owner, vis, inv = ended
                if self.can_see(owner, vis, inv, user_id):
                    await self._send(ws, {"type": "broadcast.ended", "payload": {"sid": sid, "reason": reason}})
                    return
                await self._send(ws, {"type": "broadcast.ended", "payload": {"sid": sid, "reason": "unknown"}})
                return
            # Restart API: vysílač se ještě nepřihlásil -- chvíli počkat.
            total = sum(len(w) for w in self._pending.values())
            if total >= MAX_PENDING or len(self._pending.get(sid, {})) >= MAX_PENDING_PER_SID:
                await self._send(ws, {"type": "broadcast.ended", "payload": {"sid": sid, "reason": "unknown"}})
                return
            self._pending.setdefault(sid, {})[id(ws)] = (user_id, device_id, self._now())
            self._pending_ws[id(ws)] = ws
            await self._send(ws, {"type": "broadcast.pending", "payload": {"sid": sid}})
            self._ensure_sweeper()
            return
        if not self._visible(room, user_id) or room.owner_id == user_id and room.device_id == device_id:
            # Cizí vysílání vypadá stejně jako neexistující.
            await self._send(ws, {"type": "broadcast.ended", "payload": {"sid": sid, "reason": "unknown"}})
            return
        # Jedno zařízení poslouchá jedno vysílání.
        for other in list(self.rooms.values()):
            if other is not room and id(ws) in other.listeners:
                other.listeners.pop(id(ws), None)
                await self._tell_owner(other)
        lst = room.listeners.get(id(ws))
        if lst is None:
            lst = _Listener(user_id=user_id, device_id=device_id, ws=ws)
            room.listeners[id(ws)] = lst
        lst.last_seen = self._now()
        lst.prep_ms = min(prep, PREP_MAX_MS) if prep is not None else lst.prep_ms
        # Odpověď na join vždy nese celý stav a posluchač srovnání vynuluje (N1).
        lst.sent_qv = None
        lst.sent_gen = None
        await self._send_state(room, lst, reset=True)
        # Bariéra právě běží: načíst se může taky (nečeká se na něj).
        await self._send_prepare(room, lst)
        await self._tell_owner(room)
        await self._announce()

    async def _attach_pending(self, room: Room) -> None:
        waiting = self._pending.pop(room.sid, None)
        if not waiting:
            return
        for key, (user_id, device_id, _since) in waiting.items():
            ws = self._pending_ws.pop(key, None)
            if ws is None:
                continue
            if self._visible(room, user_id):
                room.listeners[key] = _Listener(user_id=user_id, device_id=device_id, ws=ws, last_seen=self._now())
            else:
                await self._send(ws, {"type": "broadcast.ended", "payload": {"sid": room.sid, "reason": "unknown"}})

    async def leave(self, ws: Any, payload: dict[str, Any] | None = None) -> None:
        for room in list(self.rooms.values()):
            if room.listeners.pop(id(ws), None) is not None:
                await self._tell_owner(room)
        for waiting in self._pending.values():
            waiting.pop(id(ws), None)
        self._pending_ws.pop(id(ws), None)
        await self._announce()

    async def sync(self, ws: Any, payload: dict[str, Any]) -> None:
        room = self.rooms.get(payload.get("sid")) if isinstance(payload.get("sid"), str) else None
        lst = room.listeners.get(id(ws)) if room else None
        if room is None or lst is None:
            return
        lst.sent_qv = None
        await self._send_state(room, lst, reset=True)

    async def prep(self, ws: Any, payload: dict[str, Any]) -> None:
        prep = payload.get("prepMs")
        healthy = payload.get("healthy")
        for room in list(self.rooms.values()):
            lst = room.listeners.get(id(ws))
            if lst is None:
                continue
            if isinstance(prep, (int, float)) and not isinstance(prep, bool):
                lst.prep_ms = min(int(prep), PREP_MAX_MS)
            if isinstance(healthy, bool):
                lst.healthy = healthy
            await self._tell_owner(room)

    async def disconnected(self, user_id: str, ws: Any) -> None:
        """Zavřené WS: posluchač odchází (vrátí se `join` po reconnectu),
        vysílač žije dál do OFFLINE_S (může pokračovat přes HTTP)."""
        changed = False
        for room in list(self.rooms.values()):
            if room.listeners.pop(id(ws), None) is not None:
                changed = True
                await self._tell_owner(room)
            if room.owner_ws is ws:
                room.owner_ws = None
        for waiting in self._pending.values():
            waiting.pop(id(ws), None)
        self._pending_ws.pop(id(ws), None)
        if changed:
            await self._announce()

    def state_payload(self, room: Room, include_queue: bool = True, reset: bool = False) -> dict[str, Any]:
        out: dict[str, Any] = {
            "sid": room.sid,
            "name": room.owner_name,
            "clockId": CLOCK_ID,
            "gen": room.gen,
            "seq": room.seq,
            "anchor": room.anchor,
            "receivedServerMs": room.received_ms,
            "serverMs": self.server_ms(),
        }
        if reset:
            out["reset"] = True
        if include_queue:
            out["queue"] = room.queue
        return out

    async def _send_state(self, room: Room, lst: _Listener, reset: bool = False) -> None:
        if lst.ws is None:
            return
        qv = room.queue.get("qv") if room.queue else None
        include_queue = reset or lst.sent_qv != qv or lst.sent_gen != room.gen
        ok = await self._send(lst.ws, {"type": "broadcast.state", "payload": self.state_payload(room, include_queue, reset)})
        if ok:
            lst.sent_qv = qv
            lst.sent_gen = room.gen

    async def _changed(self, room: Room) -> None:
        """Nový stav: probudit long-polly a (sloučeně) rozeslat posluchačům."""
        if room.cond is not None:
            async with room.cond:
                room.cond.notify_all()
        elapsed = self._now() - room.last_flush
        if elapsed >= FLUSH_INTERVAL_S:
            await self._flush(room)
        elif room.flush_task is None or room.flush_task.done():
            room.flush_task = asyncio.create_task(self._flush_later(room, FLUSH_INTERVAL_S - elapsed))
        await self._announce()

    async def _flush_later(self, room: Room, delay: float) -> None:
        await asyncio.sleep(delay)
        if self.rooms.get(room.sid) is room:
            await self._flush(room)

    async def _flush(self, room: Room) -> None:
        room.last_flush = self._now()
        for lst in list(room.listeners.values()):
            await self._send_state(room, lst)

    async def flush_pending(self) -> None:
        """Pro testy: hned rozeslat, co čeká ve slučovacím okně."""
        for room in list(self.rooms.values()):
            if room.flush_task is not None and not room.flush_task.done():
                room.flush_task.cancel()
                room.flush_task = None
                await self._flush(room)

    # --- HTTP posluchač (iOS na pozadí, long-poll) -------------------------

    async def poll(self, user_id: str, device_id: str | None, sid: str, after: str | None, wait_s: float) -> dict[str, Any] | None:
        """Stav vysílání pro posluchače bez WS. Vrátí hned, když server má
        novější stav než `after` (`clockId.gen.seq`), nebo jiné `clockId`
        (restart API, N1); jinak čeká až `wait_s`. `None` = nic nového."""
        room = self.rooms.get(sid)
        if room is None:
            ended = self._ended.get(sid)
            if ended is not None and self.can_see(ended[2], ended[3], ended[4], user_id):
                return {"sid": sid, "ended": ended[0], "clockId": CLOCK_ID, "serverMs": self.server_ms()}
            if ended is not None:
                raise BroadcastError(404, "Vysílání neexistuje.")
            # Neznámé: buď restart API (vysílač se vrátí), nebo nikdy nebylo.
            return {"sid": sid, "pending": True, "clockId": CLOCK_ID, "serverMs": self.server_ms()}
        if not self._visible(room, user_id):
            raise BroadcastError(404, "Vysílání neexistuje.")
        key = f"http:{user_id}:{device_id or ''}"
        lst = room.listeners.get(key)
        if lst is None:
            lst = _Listener(user_id=user_id, device_id=device_id, ws=None, healthy=False)
            room.listeners[key] = lst
        lst.last_seen = self._now()

        def newer() -> bool:
            if after is None:
                return True
            parts = after.split(".")
            if len(parts) != 3 or parts[0] != CLOCK_ID:
                return True
            try:
                gen, seq = int(parts[1]), int(parts[2])
            except ValueError:
                return True
            return (room.gen, room.seq) > (gen, seq) or self.rooms.get(sid) is not room

        if not newer() and wait_s > 0:
            if self._polls.get(user_id, 0) >= MAX_POLLS_PER_USER:
                raise BroadcastError(429, "Moc souběžných dotazů.")
            self._polls[user_id] = self._polls.get(user_id, 0) + 1
            try:
                assert room.cond is not None
                async with room.cond:
                    await asyncio.wait_for(room.cond.wait_for(newer), timeout=wait_s)
            except asyncio.TimeoutError:
                pass
            finally:
                self._polls[user_id] -= 1
        if self.rooms.get(sid) is not room:
            ended = self._ended.get(sid)
            return {"sid": sid, "ended": ended[0] if ended else "stopped", "clockId": CLOCK_ID, "serverMs": self.server_ms()}
        if not newer():
            return None
        lst.last_seen = self._now()
        return self.state_payload(room, include_queue=True)

    # --- úklid -------------------------------------------------------------

    async def sweep(self) -> None:
        now = self._now()
        for room in list(self.rooms.values()):
            playing = bool(room.anchor and room.anchor.get("isPlaying"))
            if playing and now - room.last_contact > OFFLINE_S:
                await self.end(room.sid, "offline")
                continue
            # Stojí: ticho je čekané (pozastavený iPhone se na pozadí uspí, N2),
            # konec až po IDLE_S od posledního hraní.
            if not playing and now - room.last_playing > IDLE_S:
                await self.end(room.sid, "idle")
                continue
            stale = [k for k, lst in room.listeners.items() if lst.ws is None and now - lst.last_seen > HTTP_LISTENER_S]
            for k in stale:
                room.listeners.pop(k, None)
            if stale:
                await self._tell_owner(room)
                await self._announce()
        for sid, waiting in list(self._pending.items()):
            for key, (_u, _d, since) in list(waiting.items()):
                if now - since > PENDING_S:
                    waiting.pop(key, None)
                    await self._send(self._pending_ws.pop(key, None), {"type": "broadcast.ended", "payload": {"sid": sid, "reason": "unknown"}})
            if not waiting:
                self._pending.pop(sid, None)
        for sid, ended in list(self._ended.items()):
            if now - ended[1] > ENDED_KEEP_S:
                self._ended.pop(sid, None)

    def _ensure_sweeper(self) -> None:
        if self._sweeper is not None and not self._sweeper.done():
            return
        try:
            self._sweeper = asyncio.get_running_loop().create_task(self._sweep_loop())
        except RuntimeError:
            pass

    async def _sweep_loop(self) -> None:
        while self.rooms or self._pending:
            await asyncio.sleep(5)
            try:
                await self.sweep()
            except Exception:  # noqa: BLE001 -- úklid nesmí shodit hub
                logger.exception("broadcast: úklid selhal")


hub = BroadcastHub()


def allowed_invites(owner_id: str) -> set[str]:
    """Koho smí vysílač pozvat: stejné pravidlo jako Společný mix
    (routes/blends.py) -- admin kohokoli, ostatní jen profily se zapnutým
    "Sdílet, co poslouchám"."""
    from sqlmodel import Session, select

    from app.db import engine
    from app.home.extra_sections import shares_listening
    from app.models import AppUser

    with Session(engine) as session:
        me = session.get(AppUser, owner_id)
        is_admin = me is not None and me.role == "admin"
        return {
            u.id for u in session.exec(select(AppUser)).all()
            if u.id != owner_id and (is_admin or shares_listening(session, u.id))
        }


def invite_candidates(owner_id: str) -> list[dict[str, str]]:
    from sqlmodel import Session, select

    from app.db import engine
    from app.models import AppUser

    allowed = allowed_invites(owner_id)
    with Session(engine) as session:
        return [
            {"id": u.id, "name": u.name}
            for u in session.exec(select(AppUser).order_by(AppUser.name)).all()
            if u.id in allowed
        ]


def profile_name(user_id: str) -> str:
    from sqlmodel import Session

    from app.db import engine
    from app.models import AppUser

    with Session(engine) as session:
        u = session.get(AppUser, user_id)
        return (u.name if u else None) or "Někdo"
