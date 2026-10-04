"""Realtime hub: WS endpoint + Redis pub/sub listener + "Opentify Connect".

Předává eventy publikované workerem (`job.progress`, `track.available`,
viz app/events.py) na WS spojení daného uživatele.

Opentify Connect (jako Spotify Connect) -- všechna zařízení jednoho profilu
o sobě vědí:
  - `device.hello` {deviceId, name}        zařízení se představí,
  - `device.state` {nowPlaying, isPlaying, positionMs, durationMs, sourceLabel}
                                            co na něm hraje (při změně),
  - server rozešle všem `devices.update` {devices: [...]},
  - `remote.command` {target, action, value} -> cílovému zařízení
    (play / pause / toggle / next / previous / seek / stop),
  - `handoff.request` {target} -> cíl pošle `handoff.state` {to, state}
    (fronta, index, pozice) a ztichne; žadatel pokračuje u sebe.
Stav je jen v paměti procesu (jeden uvicorn) -- po restartu se zařízení
znovu představí samy.
"""

from __future__ import annotations

import json
import logging
import time
from dataclasses import dataclass, field
from typing import Any

from fastapi import WebSocket, WebSocketDisconnect

from app.redis_bus import get_redis

# Pod uvicorn.error -- jen ten má v API nastavený výpis (vlastní "vault.*" loggery
# by INFO zahodily).
logger = logging.getLogger("uvicorn.error.connect")


@dataclass
class _Device:
    ws: WebSocket
    device_id: str | None = None
    name: str = "Zařízení"
    state: dict[str, Any] = field(default_factory=dict)
    updated: float = field(default_factory=time.time)


class ConnectionManager:
    def __init__(self) -> None:
        self._connections: dict[str, dict[int, _Device]] = {}

    async def connect(self, user_id: str, ws: WebSocket) -> None:
        await ws.accept()
        self._connections.setdefault(user_id, {})[id(ws)] = _Device(ws=ws)

    def disconnect(self, user_id: str, ws: WebSocket) -> None:
        conns = self._connections.get(user_id)
        if conns:
            conns.pop(id(ws), None)
            if not conns:
                self._connections.pop(user_id, None)

    async def send_to_user(self, user_id: str, message: str) -> None:
        for dev in list(self._connections.get(user_id, {}).values()):
            await self._send(user_id, dev, message)

    async def _send(self, user_id: str, dev: _Device, message: str) -> None:
        try:
            await dev.ws.send_text(message)
        except Exception:  # noqa: BLE001 -- zařízení se mezitím odpojilo
            logger.info("connect %s: %s se odpojilo", user_id[:8], dev.name)
            self.disconnect(user_id, dev.ws)

    # --- Opentify Connect -------------------------------------------------

    def _devices(self, user_id: str) -> list[dict[str, Any]]:
        seen: dict[str, dict[str, Any]] = {}
        for dev in self._connections.get(user_id, {}).values():
            if not dev.device_id:
                continue
            seen[dev.device_id] = {
                "deviceId": dev.device_id,
                "name": dev.name,
                "updatedAt": dev.updated,
                **dev.state,
            }
        return list(seen.values())

    async def _store_playing(self, user_id: str) -> None:
        """Hraje profilu něco? Pro `app.tools.activity` (nerestartovat API,
        když poslouchá někdo jiný). Zařízení posílá stav každých ~15 s."""
        playing = any(d.state.get("isPlaying") for d in self._connections.get(user_id, {}).values())
        try:
            await get_redis().set(f"connect:playing:{user_id}", "1" if playing else "0", ex=20 * 60)
        except Exception:  # noqa: BLE001 -- jen informace pro nasazování
            pass

    async def broadcast_devices(self, user_id: str) -> None:
        message = json.dumps({"type": "devices.update", "payload": {"devices": self._devices(user_id)}})
        await self.send_to_user(user_id, message)

    def _target(self, user_id: str, device_id: str | None) -> _Device | None:
        for dev in self._connections.get(user_id, {}).values():
            if dev.device_id and dev.device_id == device_id:
                return dev
        return None

    async def handle(self, user_id: str, ws: WebSocket, raw: str) -> None:
        try:
            msg = json.loads(raw)
        except ValueError:
            return
        if not isinstance(msg, dict):
            return
        kind = msg.get("type")
        payload = msg.get("payload") if isinstance(msg.get("payload"), dict) else {}
        me = self._connections.get(user_id, {}).get(id(ws))
        if me is None:
            return
        if kind == "device.hello":
            me.device_id = str(payload.get("deviceId") or "")[:64] or None
            # Stejné zařízení po znovupřipojení: staré (napůl mrtvé) spojení pryč,
            # jinak by povely šly do něj (iOS po návratu z pozadí).
            for key, other in list(self._connections.get(user_id, {}).items()):
                # Jen se skutečným id (None == None by zavřelo cizí spojení).
                if me.device_id and other is not me and other.device_id == me.device_id:
                    self._connections[user_id].pop(key, None)
                    try:
                        await other.ws.close()
                    except Exception:  # noqa: BLE001
                        pass
            me.name = str(payload.get("name") or "Zařízení")[:60]
            me.updated = time.time()
            logger.info("connect %s: hello %s (%s), zařízení: %d", user_id[:8], me.name, (me.device_id or "")[:16], len(self._devices(user_id)))
            await self.broadcast_devices(user_id)
        elif kind == "device.state":
            allowed = ("nowPlaying", "isPlaying", "positionMs", "durationMs", "sourceLabel")
            new_state = {k: payload.get(k) for k in allowed if k in payload}
            changed = {k: v for k, v in new_state.items() if k != "positionMs"} != {
                k: v for k, v in me.state.items() if k != "positionMs"
            }
            me.state = new_state
            me.updated = time.time()
            await self._store_playing(user_id)
            # Jen pozice -> nerozesílat při každém tiku (zařízení posílá
            # stav při změně skladby/přehrávání + občas kvůli pozici).
            if changed or payload.get("broadcast"):
                np = new_state.get("nowPlaying") or {}
                logger.info("connect %s: %s %s %s", user_id[:8], me.name, "hraje" if new_state.get("isPlaying") else "stojí", np.get("title"))
                await self.broadcast_devices(user_id)
        elif kind in ("remote.command", "handoff.request", "handoff.state"):
            target = self._target(user_id, payload.get("target") or payload.get("to"))
            logger.info("connect %s: %s od %s -> %s", user_id[:8], kind, me.name, target.name if target else "NENALEZENO")
            if target is None or target is me:
                return
            forward = {k: v for k, v in payload.items() if k not in ("target", "to")}
            forward["from"] = me.device_id
            await self._send(user_id, target, json.dumps({"type": kind, "payload": forward}))
        elif kind == "ping":
            # Klient podle odpovědi pozná mrtvý socket (iOS po pozadí).
            await self._send(user_id, me, '{"type": "pong", "payload": {}}')
        elif kind == "devices.list":
            await self._send(
                user_id, me, json.dumps({"type": "devices.update", "payload": {"devices": self._devices(user_id)}})
            )


manager = ConnectionManager()


async def websocket_endpoint(websocket: WebSocket, user_id: str) -> None:
    await manager.connect(user_id, websocket)
    try:
        while True:
            raw = await websocket.receive_text()
            if len(raw) > 512_000:  # fronta při převzetí je největší zpráva
                continue
            await manager.handle(user_id, websocket, raw)
    except WebSocketDisconnect:
        pass
    finally:
        manager.disconnect(user_id, websocket)
        await manager._store_playing(user_id)
        await manager.broadcast_devices(user_id)


async def redis_listener() -> None:
    """Události workeru (stažení hotové...) -> zařízení. Při výpadku Redisu
    se znovu připojí -- dřív jeden výpadek umlčel živé zprávy do restartu API."""
    import asyncio

    delay = 1.0
    while True:
        try:
            r = get_redis()
            pubsub = r.pubsub()
            await pubsub.psubscribe("vault:events:user:*")
            logger.info("realtime hub poslouchá Redis pub/sub")
            delay = 1.0
            async for message in pubsub.listen():
                if message["type"] != "pmessage":
                    continue
                channel: str = message["channel"]
                user_id = channel.rsplit(":", 1)[-1]
                await manager.send_to_user(user_id, message["data"])
        except asyncio.CancelledError:
            raise
        except Exception as exc:  # noqa: BLE001
            logger.warning("realtime: Redis pub/sub spadl (%s), znovu za %.0f s", exc, delay)
            await asyncio.sleep(delay)
            delay = min(delay * 2, 30.0)
