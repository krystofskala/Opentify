"""Sdílený stream (app/broadcast.py): vysílání v paměti, viditelnost, pořadí
od serveru, slučování bez ztráty stavu, HTTP pro iOS na pozadí, úklid."""
from __future__ import annotations

import asyncio
import json
import uuid

import pytest
from sqlmodel import Session

import app.broadcast as bc
from app.db import engine
from app.models import AppUser, HomeSnapshot


class FakeWS:
    def __init__(self) -> None:
        self.sent: list[dict] = []

    async def send_text(self, text: str) -> None:
        self.sent.append(json.loads(text))

    def of(self, kind: str) -> list[dict]:
        return [m["payload"] for m in self.sent if m["type"] == kind]


class Clock:
    def __init__(self) -> None:
        self.t = 1000.0

    def __call__(self) -> float:
        return self.t


def _id() -> str:
    return uuid.uuid4().hex


def _anchor(rid: str = "rec-a", pos: int = 0, playing: bool = True, **kw) -> dict:
    return {"recordingId": rid, "index": kw.pop("index", 0), "qv": kw.pop("qv", 1), "positionMs": pos,
            "atServerMs": 5000, "rate": 1.0, "isPlaying": playing, **kw}


def _queue(qv: int = 1, ids=("rec-a", "rec-b")) -> dict:
    return {"qv": qv, "baseIndex": 0, "items": [{"recordingId": r, "title": f"T {r}", "artistName": "A"} for r in ids]}


def _start(sid, bid, **kw) -> dict:
    return {"sid": sid, "bid": bid, "visibility": kw.pop("visibility", "invited"), "invited": kw.pop("invited", []),
            "queue": kw.pop("queue", _queue()), "anchor": kw.pop("anchor", _anchor()), **kw}


def _hub():
    clock = Clock()
    hub = bc.BroadcastHub(clock=clock)
    return hub, clock


def test_start_join_state_leave_stop_and_list_shows_only_name() -> None:
    async def run():
        hub, clock = _hub()
        owner_ws, lis_ws, other_ws = FakeWS(), FakeWS(), FakeWS()
        sid, bid = _id(), _id()
        hub.connections = lambda: [("owner", owner_ws), ("friend", lis_ws), ("stranger", other_ws)]
        await hub.start("owner", "Kryštof", "dev-o", _start(sid, bid, invited=["friend", "stranger"]), {"friend"}, owner_ws)
        # Seznam: nepozvaný nic nevidí, pozvaný jen jméno + skladbu + počet.
        assert hub.visible_list("stranger") == []
        [item] = hub.visible_list("friend")
        assert item["name"] == "Kryštof" and item["listeners"] == 0
        assert item["track"]["title"] == "T rec-a"
        assert set(item) == {"id", "name", "mine", "isPlaying", "track", "listeners"}
        assert bid not in json.dumps(item) and "dev-o" not in json.dumps(item)

        await hub.join("friend", "dev-f", lis_ws, {"sid": sid, "prepMs": 300})
        [st] = lis_ws.of("broadcast.state")
        assert st["reset"] and st["queue"]["items"][0]["recordingId"] == "rec-a"
        assert st["clockId"] == bc.CLOCK_ID and st["gen"] == 1
        assert owner_ws.of("broadcast.listeners")[-1] == {"sid": sid, "count": 1, "prepMs": 300}
        assert hub.is_listening("friend", "dev-f") and not hub.is_listening("owner", "dev-o")

        clock.t += 1
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 1, "anchor": _anchor("rec-b", index=1)})
        st = lis_ws.of("broadcast.state")[-1]
        assert st["anchor"]["recordingId"] == "rec-b" and "queue" not in st  # fronta beze změny se neposílá

        await hub.leave(lis_ws, {"sid": sid})
        assert hub.visible_list("friend")[0]["listeners"] == 0
        await hub.join("friend", "dev-f", lis_ws, {"sid": sid})
        await hub.stop("owner", {"sid": sid, "bid": bid})
        assert lis_ws.of("broadcast.ended")[-1]["reason"] == "stopped"
        assert hub.visible_list("friend") == []
        assert not hub.is_listening("friend", "dev-f")

    asyncio.run(run())


def test_stranger_cannot_join_and_server_visibility_opens_it() -> None:
    async def run():
        hub, _clock = _hub()
        sid, bid = _id(), _id()
        await hub.start("owner", "K", None, _start(sid, bid, invited=["x"]), {"x"})
        ws = FakeWS()
        await hub.join("stranger", None, ws, {"sid": sid})
        assert ws.of("broadcast.ended")[0]["reason"] == "unknown" and not ws.of("broadcast.state")
        # Pozvat smí jen profily, které pravidlo dovolí (allowed_invites).
        sid2, bid2 = _id(), _id()
        room = await hub.start("owner2", "L", None, _start(sid2, bid2, invited=["a", "b"]), {"a"})
        assert room.invited == {"a"}
        # "Všichni na serveru".
        sid3, bid3 = _id(), _id()
        await hub.start("owner3", "M", None, _start(sid3, bid3, visibility="server"), set())
        ws3 = FakeWS()
        await hub.join("stranger", None, ws3, {"sid": sid3})
        assert ws3.of("broadcast.state")

    asyncio.run(run())


def test_order_from_server_takeover_and_late_http_message() -> None:
    async def run():
        hub, _clock = _hub()
        owner_ws, new_ws, lis = FakeWS(), FakeWS(), FakeWS()
        sid, bid = _id(), _id()
        await hub.start("owner", "K", "d1", _start(sid, bid, visibility="server"), set(), owner_ws)
        await hub.join("u", None, lis, {"sid": sid})
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 5, "anchor": _anchor(pos=5000)})
        # Zpožděná starší zpráva (HTTP po WS) nepřepíše novější stav.
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 4, "anchor": _anchor(pos=1000)})
        assert hub.rooms[sid].anchor["positionMs"] == 5000
        # Převzetí jiným zařízením: nový bid -> nová generace, bseq od nuly platí.
        bid2 = _id()
        await hub.start("owner", "K", "d2", _start(sid, bid2, visibility="server", bseq=0), set(), new_ws)
        assert owner_ws.of("broadcast.taken")
        await hub.flush_pending()
        await hub.state("owner", {"sid": sid, "bid": bid2, "bseq": 1, "anchor": _anchor(pos=200)})
        await hub.flush_pending()
        last = lis.of("broadcast.state")[-1]
        assert last["gen"] == 2 and last["anchor"]["positionMs"] == 200
        # Nová generace = posluchač dostane i frontu znovu.
        assert any("queue" in m for m in lis.of("broadcast.state") if m["gen"] == 2)
        # Staré zařízení už nic neposlat nesmí.
        with pytest.raises(bc.BroadcastError) as e:
            await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 99, "anchor": _anchor()})
        assert e.value.status == 410
        # Jiný profil se sid stejně nic nezmůže.
        with pytest.raises(bc.BroadcastError) as e:
            await hub.state("intruder", {"sid": sid, "bid": bid2, "bseq": 100, "anchor": _anchor()})
        assert e.value.status == 403
        with pytest.raises(bc.BroadcastError) as e:
            await hub.start("intruder", "X", None, _start(sid, _id()), set())
        assert e.value.status == 403

    asyncio.run(run())


def test_unknown_sid_is_409_and_ended_is_410() -> None:
    async def run():
        hub, _clock = _hub()
        with pytest.raises(bc.BroadcastError) as e:
            await hub.state("owner", {"sid": _id(), "bid": _id(), "bseq": 1, "anchor": _anchor()})
        assert e.value.status == 409
        sid, bid = _id(), _id()
        await hub.start("owner", "K", None, _start(sid, bid), set())
        await hub.stop("owner", {"sid": sid, "bid": bid})
        with pytest.raises(bc.BroadcastError) as e:
            await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 2, "anchor": _anchor()})
        assert e.value.status == 410

    asyncio.run(run())


def test_coalescing_keeps_latest_state_and_queue() -> None:
    """Rychlé přeskoky + úprava fronty v jednom okně: posluchač dostane
    poslední kotvu I novou frontu (nic se nezahodí, N4)."""

    async def run():
        hub, clock = _hub()
        lis = FakeWS()
        sid, bid = _id(), _id()
        await hub.start("owner", "K", None, _start(sid, bid, visibility="server"), set())
        await hub.join("u", None, lis, {"sid": sid})
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 1, "anchor": _anchor("rec-b", index=1)})
        before = len(lis.of("broadcast.state"))
        # Ve stejném okně: nová fronta, pak několik kotev bez fronty.
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 2, "queue": _queue(2, ("rec-a", "rec-b", "rec-c")),
                                  "anchor": _anchor("rec-c", index=2, qv=2)})
        for i in range(3, 9):
            await hub.state("owner", {"sid": sid, "bid": bid, "bseq": i, "anchor": _anchor("rec-c", pos=i, index=2, qv=2)})
        assert len(lis.of("broadcast.state")) == before  # zatím sloučeno
        await hub.flush_pending()
        last = lis.of("broadcast.state")[-1]
        assert last["anchor"]["positionMs"] == 8 and last["queue"]["qv"] == 2
        assert len(lis.of("broadcast.state")) == before + 1
        # Plán přechodu téže skladby přežije heartbeat bez plánu.
        clock.t += 1
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 20, "anchor": _anchor("rec-c", index=2, qv=2, transitionAtServerMs=99_000)})
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 21, "anchor": _anchor("rec-c", pos=50, index=2, qv=2)})
        assert hub.rooms[sid].anchor["transitionAtServerMs"] == 99_000

    asyncio.run(run())


def test_clock_not_ok_drops_plans() -> None:
    a = bc.clean_anchor(_anchor(startAtServerMs=1, transitionAtServerMs=2, clockOk=False))
    assert "startAtServerMs" not in a and "transitionAtServerMs" not in a and a["clockOk"] is False
    assert bc.clean_anchor({"positionMs": 1}) is None  # bez skladby to není kotva


def test_liveness_offline_while_playing_idle_while_paused() -> None:
    async def run():
        hub, clock = _hub()
        lis = FakeWS()
        sid, bid = _id(), _id()
        await hub.start("owner", "K", None, _start(sid, bid, visibility="server"), set())
        await hub.join("u", None, lis, {"sid": sid})
        clock.t += 80
        await hub.sweep()
        assert sid in hub.rooms  # 80 s bez kontaktu ještě ne
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 1})  # HTTP heartbeat bez kotvy
        clock.t += 80
        await hub.sweep()
        assert sid in hub.rooms
        clock.t += 11
        await hub.sweep()
        assert sid not in hub.rooms and lis.of("broadcast.ended")[-1]["reason"] == "offline"

        # Pozastavený vysílač mlčí (iOS se uspí) -- to je v pořádku do 30 min.
        sid2, bid2 = _id(), _id()
        await hub.start("owner", "K", None, _start(sid2, bid2, visibility="server"), set())
        await hub.state("owner", {"sid": sid2, "bid": bid2, "bseq": 1, "anchor": _anchor(playing=False)})
        clock.t += 20 * 60
        await hub.sweep()
        assert sid2 in hub.rooms
        clock.t += 11 * 60
        await hub.sweep()
        assert sid2 not in hub.rooms

    asyncio.run(run())


def test_pending_listener_attaches_after_api_restart() -> None:
    async def run():
        hub, clock = _hub()  # "nový proces": vysílání neexistuje
        lis, late = FakeWS(), FakeWS()
        sid, bid = _id(), _id()
        await hub.join("u", None, lis, {"sid": sid})
        await hub.join("u2", None, late, {"sid": _id()})
        assert lis.of("broadcast.pending")
        await hub.start("owner", "K", None, _start(sid, bid, visibility="server"), set())
        assert lis.of("broadcast.state")
        clock.t += 61
        await hub.sweep()
        assert late.of("broadcast.ended")[-1]["reason"] == "unknown"

    asyncio.run(run())


def test_http_poll_long_wait_and_clock_reset() -> None:
    async def run():
        hub = bc.BroadcastHub()
        sid, bid = _id(), _id()
        room = await hub.start("owner", "K", None, _start(sid, bid, invited=["friend"]), {"friend"})
        with pytest.raises(bc.BroadcastError) as e:
            await hub.poll("stranger", None, sid, None, 0)
        assert e.value.status == 404
        first = await hub.poll("friend", "phone", sid, None, 0)
        assert first["anchor"]["recordingId"] == "rec-a" and first["queue"]
        after = f"{first['clockId']}.{first['gen']}.{first['seq']}"
        assert await hub.poll("friend", "phone", sid, after, 0) is None
        # Jiné clockId (restart API) -> hned celý stav (N1).
        assert (await hub.poll("friend", "phone", sid, f"jine.{room.gen}.{room.seq}", 0))["seq"] == room.seq
        assert hub.is_listening("friend", "phone")

        async def later():
            await asyncio.sleep(0.05)
            await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 1, "anchor": _anchor(pos=777)})

        task = asyncio.create_task(later())
        got = await hub.poll("friend", "phone", sid, after, 2.0)
        await task
        assert got["anchor"]["positionMs"] == 777
        # Konec vysílání probudí čekajícího.
        after = f"{got['clockId']}.{got['gen']}.{got['seq']}"

        async def stop():
            await asyncio.sleep(0.05)
            await hub.stop("owner", {"sid": sid, "bid": bid})

        task = asyncio.create_task(stop())
        got = await hub.poll("friend", "phone", sid, after, 2.0)
        await task
        assert got["ended"] == "stopped"
        unknown = await hub.poll("friend", "phone", _id(), None, 0)
        assert unknown["pending"] is True

    asyncio.run(run())


def test_replaced_broadcast_ends_old_one() -> None:
    async def run():
        hub, _clock = _hub()
        old_ws, lis = FakeWS(), FakeWS()
        sid, bid = _id(), _id()
        await hub.start("owner", "K", None, _start(sid, bid, visibility="server"), set(), old_ws)
        await hub.join("u", None, lis, {"sid": sid})
        await hub.start("owner", "K", None, _start(_id(), _id(), visibility="server"), set())
        assert sid not in hub.rooms and lis.of("broadcast.ended")[-1]["reason"] == "replaced"
        assert old_ws.of("broadcast.taken")

    asyncio.run(run())


def test_queue_limit_and_garbage_fields() -> None:
    q = bc.clean_queue({"qv": 3, "items": [{"recordingId": str(i)} for i in range(800)] + ["x"]})
    assert len(q["items"]) == bc.MAX_QUEUE
    q = bc.clean_queue({"items": [{"recordingId": "r", "id": "r", "t": "T", "d": 1000, "evil": "<x>", "nested": {"a": 1}}]})
    assert q["items"] == [{"recordingId": "r", "id": "r", "t": "T", "d": 1000}]
    a = bc.clean_anchor({"recordingId": "r", "positionMs": "5", "evil": 1, "rate": True})
    assert "positionMs" not in a and "evil" not in a and "rate" not in a


def test_allowed_invites_follow_blend_rule() -> None:
    run = uuid.uuid4().hex[:6]
    with Session(engine) as s:
        owner = AppUser(name=f"o-{run}")
        sharing = AppUser(name=f"s-{run}")
        private = AppUser(name=f"p-{run}")
        s.add_all([owner, sharing, private])
        s.commit()
        from app.home.extra_sections import share_key

        s.add(HomeSnapshot(key=share_key(sharing.id), payload={"on": True}))
        s.commit()
        ids = owner.id, sharing.id, private.id
    allowed = bc.allowed_invites(ids[0])
    assert ids[1] in allowed and ids[2] not in allowed and ids[0] not in allowed
    assert bc.profile_name(ids[0]) == f"o-{run}"


def test_http_routes_require_login_and_work(monkeypatch) -> None:
    from fastapi.testclient import TestClient

    from app.main import app

    monkeypatch.setattr("app.auth.auth_mode", lambda: "login")
    client = TestClient(app)
    r = client.get("/api/v1/broadcasts")
    assert r.status_code == 401


def test_connect_device_state_of_listener_skips_backup_listens(monkeypatch) -> None:
    from app import realtime

    calls = []
    monkeypatch.setattr("app.connect_listens.tracker.update", lambda *a: calls.append(a))

    async def run():
        hub = bc.hub
        mgr = realtime.ConnectionManager()
        ws = FakeWS()
        ws.accept = lambda: asyncio.sleep(0)
        await mgr.connect("lis-user", ws)
        await mgr.handle("lis-user", ws, json.dumps({"type": "device.hello", "payload": {"deviceId": "dev-lis", "name": "x"}}))
        sid, bid = _id(), _id()
        await hub.start("own-user", "K", None, _start(sid, bid, visibility="server"), set())
        await mgr.handle("lis-user", ws, json.dumps({"type": "broadcast.join", "payload": {"sid": sid}}))
        assert ws.of("broadcast.state")
        state = {"type": "device.state", "payload": {"nowPlaying": {"recordingId": "rec-a"}, "isPlaying": True, "positionMs": 1}}
        await mgr.handle("lis-user", ws, json.dumps(state))
        assert calls == []
        await mgr.handle("lis-user", ws, json.dumps({"type": "broadcast.leave", "payload": {"sid": sid}}))
        await mgr.handle("lis-user", ws, json.dumps(state))
        assert len(calls) == 1
        # Hodiny: pong nese c0, čas serveru a id hodin.
        await mgr.handle("lis-user", ws, json.dumps({"type": "clock.ping", "payload": {"c0": 12.5}}))
        pong = ws.of("clock.pong")[-1]
        assert pong["c0"] == 12.5 and pong["clockId"] == bc.CLOCK_ID and isinstance(pong["s"], float)
        await hub.end(sid, "stopped")

    monkeypatch.setattr(realtime.ConnectionManager, "_store_playing", lambda self, u: asyncio.sleep(0))
    asyncio.run(run())


def test_pending_listeners_are_capped(monkeypatch) -> None:
    monkeypatch.setattr(bc, "MAX_PENDING_PER_SID", 2)

    async def run():
        hub, _clock = _hub()
        sid = _id()
        socks = [FakeWS() for _ in range(3)]
        for ws in socks:
            await hub.join("u", None, ws, {"sid": sid})
        assert socks[0].of("broadcast.pending") and socks[1].of("broadcast.pending")
        assert socks[2].of("broadcast.ended")[0]["reason"] == "unknown"

    asyncio.run(run())


def test_clock_not_ok_anchor_is_restamped_and_start_plan_not_carried() -> None:
    """Test 16. 10.: kotva vysílače bez hodin nesla klientský čas a plán
    startu se přenášel do změřených kotev -- posluchač o 30 s napřed."""

    async def run():
        hub, clock = _hub()
        sid, bid = _id(), _id()
        await hub.start("owner", "K", None, _start(sid, bid, visibility="server"), set())
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 1,
                                  "anchor": _anchor("rec-b", index=1, atServerMs=12, clockOk=False)})
        assert hub.rooms[sid].anchor["atServerMs"] == hub.server_ms()
        start_at = hub.server_ms() + 600
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 2,
                                  "anchor": _anchor("rec-c", index=2, atServerMs=start_at, startAtServerMs=start_at)})
        clock.t += 1
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 3,
                                  "anchor": _anchor("rec-c", pos=400, index=2, atServerMs=start_at + 400)})
        assert "startAtServerMs" not in hub.rooms[sid].anchor

    asyncio.run(run())


# --- ready bariéra (16. 10.) -------------------------------------------------


async def _room_with(hub, n_listeners=2, **kw):
    owner_ws = FakeWS()
    sid, bid = _id(), _id()
    await hub.start("owner", "K", "dev-o", _start(sid, bid, visibility="server"), set(), owner_ws)
    lis = [FakeWS() for _ in range(n_listeners)]
    for i, ws in enumerate(lis):
        await hub.join(f"u{i}", f"d{i}", ws, {"sid": sid})
    return sid, bid, owner_ws, lis


def _prepare(sid, bid, bseq, kind="start", rid="rec-b", pos=0):
    return {"sid": sid, "bid": bid, "bseq": bseq, "kind": kind, "anchor": _anchor(rid, pos=pos, index=1)}


def test_barrier_go_after_everyone_ready_with_lead_from_rtt_and_start_lead() -> None:
    async def run():
        hub, clock = _hub()
        sid, bid, owner_ws, lis = await _room_with(hub)
        await hub.prepare("owner", _prepare(sid, bid, 1))
        epoch = owner_ws.of("broadcast.prepared")[-1]["epoch"]
        assert all(ws.of("broadcast.prepare")[-1]["epoch"] == epoch for ws in lis)
        # Do go stojí -- seznam / pozdní příchozí vidí pauzu.
        assert hub.rooms[sid].anchor["isPlaying"] is False
        await hub.ready("owner", owner_ws, {"sid": sid, "epoch": epoch, "rtt": 40, "startLeadMs": 900})
        await hub.ready("u0", lis[0], {"sid": sid, "epoch": epoch, "rtt": 60})
        assert not lis[0].of("broadcast.go")  # čeká se na druhého
        await hub.ready("u1", lis[1], {"sid": sid, "epoch": epoch, "rtt": 600})
        go = lis[1].of("broadcast.go")[-1]
        assert go == lis[0].of("broadcast.go")[-1] == owner_ws.of("broadcast.go")[-1]
        lead = go["atServerMs"] - go["serverMs"]
        # 1,5 × 600 = 900 < nejdelší rozjezd 900 + 200 -> 1100 + rezerva 300.
        assert abs(lead - 1400) < 5
        assert go["anchor"]["startAtServerMs"] == go["atServerMs"] and go["anchor"]["isPlaying"] is True
        assert hub.rooms[sid].barrier is None

    asyncio.run(run())


def test_barrier_timeout_marks_lagging_and_waits_for_broadcaster() -> None:
    async def run():
        hub, clock = _hub()
        sid, bid, owner_ws, lis = await _room_with(hub)
        await hub.prepare("owner", _prepare(sid, bid, 1))
        epoch = hub.rooms[sid].barrier["epoch"]
        await hub.ready("u0", lis[0], {"sid": sid, "epoch": epoch, "rtt": 50})
        clock.t += 5  # po limitu 4 s, ale vysílač ještě není ready
        await hub.check_barrier(hub.rooms[sid])
        assert not lis[0].of("broadcast.go")
        await hub.ready("owner", owner_ws, {"sid": sid, "epoch": epoch, "rtt": 50})
        assert lis[0].of("broadcast.go") and lis[1].of("broadcast.go")
        room = hub.rooms[sid]
        assert room.listeners[id(lis[1])].lagging and not room.listeners[id(lis[0])].lagging
        # Vysílač, který se nenačte vůbec: bariéra se po 15 s zruší.
        await hub.prepare("owner", _prepare(sid, bid, 2, rid="rec-c"))
        clock.t += 16
        await hub.check_barrier(room)
        assert room.barrier is None

    asyncio.run(run())


def test_old_epoch_ready_ignored_and_pause_cancels_barrier() -> None:
    async def run():
        hub, clock = _hub()
        sid, bid, owner_ws, lis = await _room_with(hub, 1)
        await hub.prepare("owner", _prepare(sid, bid, 1))
        old = hub.rooms[sid].barrier["epoch"]
        await hub.prepare("owner", _prepare(sid, bid, 2, rid="rec-c"))  # rychlý přeskok
        await hub.ready("owner", owner_ws, {"sid": sid, "epoch": old})
        await hub.ready("u0", lis[0], {"sid": sid, "epoch": old})
        assert not lis[0].of("broadcast.go") and hub.rooms[sid].barrier["epoch"] == old + 1
        # Pauza bariéru nemá a rozběhnutou ruší.
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 3, "anchor": _anchor("rec-c", pos=0, index=1, playing=False)})
        assert hub.rooms[sid].barrier is None

    asyncio.run(run())


def test_suspended_listener_does_not_hold_the_group() -> None:
    async def run():
        hub, clock = _hub()
        sid, bid, owner_ws, lis = await _room_with(hub)
        await hub.prepare("owner", _prepare(sid, bid, 1))
        epoch = hub.rooms[sid].barrier["epoch"]
        await hub.ready("owner", owner_ws, {"sid": sid, "epoch": epoch})
        await hub.ready("u0", lis[0], {"sid": sid, "epoch": epoch})
        await hub.suspend(lis[1], {"sid": sid, "reason": "buffering"})
        assert lis[0].of("broadcast.go")

    asyncio.run(run())


def test_late_joiner_and_solo_prepared_start() -> None:
    async def run():
        hub, clock = _hub()
        sid, bid, owner_ws, lis = await _room_with(hub, 0)
        # Hraje: pozice 10 000 v čase serveru teď.
        now = hub.server_ms()
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 1, "anchor": _anchor("rec-a", pos=10000, atServerMs=now)})
        late = FakeWS()
        await hub.join("late", "dl", late, {"sid": sid})
        assert late.of("broadcast.state")
        # Zaparkoval na 13 000 (vysílač tam bude za 3 s) -> go přesně tam.
        await hub.ready("late", late, {"sid": sid, "solo": True, "recordingId": "rec-a", "index": 0, "positionMs": 13000, "rtt": 50, "startLeadMs": 400})
        go = late.of("broadcast.go")[-1]
        assert go["solo"] and go["positionMs"] == 13000 and abs(go["atServerMs"] - (now + 3000)) < 1
        # Zaparkoval moc blízko (vysílač tam bude za 100 ms) -> nejbližší čas a pozice v něm.
        now = hub.server_ms()
        await hub.ready("late", late, {"sid": sid, "solo": True, "recordingId": "rec-a", "index": 0, "positionMs": 10100, "rtt": 50, "startLeadMs": 400})
        go = late.of("broadcast.go")[-1]
        lead = go["atServerMs"] - go["serverMs"]
        assert abs(lead - 900) < 5 and abs(go["positionMs"] - (10000 + (go["atServerMs"] - now))) < 1
        # Jiná skladba než u vysílače -> dostane stav a go s retry (žádné ticho).
        await hub.ready("late", late, {"sid": sid, "solo": True, "recordingId": "rec-x", "index": 5, "positionMs": 0})
        assert late.of("broadcast.go")[-1]["retry"] is True and late.of("broadcast.state")[-1]["reset"]

    asyncio.run(run())


def test_go_lead_rules() -> None:
    assert bc.go_lead_ms([]) == 800  # bez dat: 500 + 300
    assert bc.go_lead_ms([1000]) == 1800
    assert bc.go_lead_ms([50], [1200]) == 1700


# --- organizátor a přidávání posluchači (16. 10.) ---------------------------


def test_listener_adds_to_stream_queue_with_limits_and_owner_ack(monkeypatch) -> None:
    monkeypatch.setattr(bc, "profile_name", lambda uid: {"u0": "Kryštof"}.get(uid, "?"))

    async def run():
        hub, clock = _hub()
        sid, bid, owner_ws, lis = await _room_with(hub, 1)
        item = {"recordingId": "rec-x", "id": "rec-x", "t": "Song X", "evil": "<x>"}
        assert await hub.add_item("u0", lis[0], {"sid": sid, "item": item}) is None
        added = owner_ws.of("broadcast.added")[-1]
        assert added["by"] == "Kryštof" and added["item"]["byId"] == "u0" and "evil" not in added["item"]
        # Rate limit 1 za 2 s.
        assert "rychle" in await hub.add_item("u0", lis[0], {"sid": sid, "item": item})
        # Nepřipojený (i když by vysílání viděl) nepřidá.
        stranger = FakeWS()
        assert await hub.add_item("u9", stranger, {"sid": sid, "item": item}) is not None
        # Limit 10 čekajících.
        for _ in range(9):
            clock.t += 3
            assert await hub.add_item("u0", lis[0], {"sid": sid, "item": item}) is None
        clock.t += 3
        assert "Čeká už" in await hub.add_item("u0", lis[0], {"sid": sid, "item": item})
        # Vysílač je zařadil do fronty a dvě se už zahrály -> zase jde přidávat.
        room = hub.rooms[sid]
        adds = [a["item"] for a in room.pending_adds]
        q = {"qv": 2, "baseIndex": 0, "items": [{"recordingId": "rec-a", "id": "rec-a", "t": "A"}] + adds}
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 50, "queue": q, "anchor": _anchor("rec-x", index=2, qv=2)})
        assert room.pending_adds == []
        assert hub._waiting_adds(room, "u0") == 8
        assert await hub.add_item("u0", lis[0], {"sid": sid, "item": item}) is None
        # Pořadí přidaných: addId roste.
        ids = [int(a["addId"]) for a in adds]
        assert ids == sorted(ids)

    asyncio.run(run())


def test_only_broadcaster_skips_or_seeks() -> None:
    async def run():
        hub, clock = _hub()
        sid, bid, owner_ws, lis = await _room_with(hub, 1)
        for call in (hub.prepare, hub.state):
            with pytest.raises(bc.BroadcastError) as e:
                await call("u0", {"sid": sid, "bid": bid, "bseq": 99, "anchor": _anchor("rec-z")})
            assert e.value.status == 403

    asyncio.run(run())


def test_live_16_oct_solo_always_answered_even_when_broadcaster_never_ready() -> None:
    """Živě 16. 10.: vysílač nikdy neposlal ready, posluchač parkoval a
    posílal solo ready dokola bez odpovědi. Teď vždy přijde odpověď a visící
    bariéra se po limitu zruší."""

    async def run():
        hub, clock = _hub()
        sid, bid, owner_ws, lis = await _room_with(hub, 1)
        now = hub.server_ms()
        await hub.state("owner", {"sid": sid, "bid": bid, "bseq": 1, "anchor": _anchor("rec-a", pos=84751, atServerMs=now)})
        # Bez bariéry: solo dostane go.
        await hub.ready("u0", lis[0], {"sid": sid, "solo": True, "recordingId": "rec-a", "index": 0, "positionMs": 84751 + 3000, "rtt": 26})
        assert lis[0].of("broadcast.go")[-1].get("atServerMs")
        # Vysílač začne bariéru a nikdy nepošle ready.
        await hub.prepare("owner", _prepare(sid, bid, 2))
        await hub.ready("u0", lis[0], {"sid": sid, "solo": True, "recordingId": "rec-b", "index": 1, "positionMs": 3000})
        assert lis[0].of("broadcast.go")[-1]["wait"] is True
        clock.t += 9  # po limitu vysílače
        await hub.ready("u0", lis[0], {"sid": sid, "solo": True, "recordingId": "rec-b", "index": 1, "positionMs": 3000})
        last = lis[0].of("broadcast.go")[-1]
        assert hub.rooms[sid].barrier is None and "wait" not in last
        # Kotva po zrušené bariéře stojí -> go říká "stojí" (žádné parkování dokola).
        assert last["isPlaying"] is False
        # Jiná skladba než u vysílače -> retry s důvodem, ne ticho.
        await hub.ready("u0", lis[0], {"sid": sid, "solo": True, "recordingId": "rec-x", "index": 9, "positionMs": 0})
        assert lis[0].of("broadcast.go")[-1] == {**lis[0].of("broadcast.go")[-1], "retry": True, "reason": "track"}

    asyncio.run(run())


def test_concurrent_adds_get_unique_add_ids(monkeypatch) -> None:
    # EX2-2 nález 14 (Codex): addId se četl až po await -- dva současně přidávající
    # posluchači dostali stejné, potvrzení jednoho pak smazalo obě čekající.
    import time as _time

    monkeypatch.setattr(bc, "profile_name", lambda uid: (_time.sleep(0.05), uid)[1])

    async def run():
        hub, _clock = _hub()
        sid, _bid, owner_ws, lis = await _room_with(hub, 2)
        item = {"recordingId": "rec-x", "id": "rec-x", "t": "Song X"}
        res = await asyncio.gather(*(hub.add_item(f"u{i}", lis[i], {"sid": sid, "item": item}) for i in range(2)))
        assert res == [None, None]
        ids = [a["addId"] for a in hub.rooms[sid].pending_adds]
        assert len(ids) == 2 and len(set(ids)) == 2

    asyncio.run(run())


def test_poll_after_listener_removed_while_waiting() -> None:
    # EX2-2 nález 1 (Codex): čekající long-poll po odebrání pozvánky vrátil ještě celý stav.
    async def run():
        hub = bc.BroadcastHub()
        sid, bid = _id(), _id()
        await hub.start("owner", "K", None, _start(sid, bid, invited=["friend"]), {"friend"})
        first = await hub.poll("friend", "phone", sid, None, 0)
        after = f"{first['clockId']}.{first['gen']}.{first['seq']}"

        async def remove():
            await asyncio.sleep(0.05)
            await hub.start("owner", "K", None, _start(sid, bid, invited=[]), set())

        task = asyncio.create_task(remove())
        with pytest.raises(bc.BroadcastError) as e:
            await hub.poll("friend", "phone", sid, after, 2.0)
        await task
        assert e.value.status == 404
        assert "friend" not in hub._polls

    asyncio.run(run())
