"""Verwaltet WebSocket-Verbindungen der Tablets und verteilt Live-Updates raumgefiltert."""
from dataclasses import dataclass

from fastapi import WebSocket

from . import db

# Zustaende, bei denen ein Praesenz-/Bewegungsmelder "jemand ist da" meldet
PRESENT_STATES = {"on", "home", "detected"}


@dataclass
class Client:
    tablet_id: str
    room_id: str | None
    wake_mode: str  # camera | sensor | both


class Hub:
    def __init__(self) -> None:
        self.clients: dict[WebSocket, Client] = {}

    async def add(self, ws: WebSocket, tablet_id: str, room_id: str | None, wake_mode: str) -> None:
        await ws.accept()
        self.clients[ws] = Client(tablet_id, room_id, wake_mode)

    def online(self) -> set[str]:
        return {c.tablet_id for c in self.clients.values()}

    async def reload(self, tablet_id: str | None = None, room_id: str | None = None) -> None:
        """Einstellungen geaendert: betroffene Tablets neu verbinden lassen, damit sie neu laden."""
        for ws, c in list(self.clients.items()):
            if c.tablet_id == tablet_id or (room_id and c.room_id == room_id):
                self.remove(ws)
                try:
                    await ws.close(code=4000)
                except Exception:  # noqa: BLE001
                    pass

    def remove(self, ws: WebSocket) -> None:
        self.clients.pop(ws, None)

    async def _send(self, ws: WebSocket, msg: dict) -> None:
        try:
            await ws.send_json(msg)
        except Exception:  # noqa: BLE001
            self.remove(ws)

    async def wake_room(self, room_id: str, reason: str) -> None:
        for ws, c in list(self.clients.items()):
            if c.room_id == room_id and c.wake_mode in ("sensor", "both"):
                await self._send(ws, {"type": "wake", "reason": reason})

    async def on_state_changed(self, state: dict) -> None:
        entity_id = state["entity_id"]
        if state["state"] in PRESENT_STATES:
            for room_id in db.rooms_for_presence(entity_id):
                await self.wake_room(room_id, entity_id)
        rooms = set(db.rooms_for_entity(entity_id))
        for ws, c in list(self.clients.items()):
            if c.room_id in rooms:
                await self._send(ws, {"type": "state", "state": state})


hub = Hub()
