"""Verwaltet WebSocket-Verbindungen der Tablets und verteilt Live-Updates raumgefiltert."""
from dataclasses import dataclass

from fastapi import WebSocket

from . import db

# Zustaende, bei denen ein Praesenz-/Bewegungsmelder "jemand ist da" meldet
PRESENT_STATES = {"on", "home", "detected"}


@dataclass
class Client:
    room_id: str | None
    wake_mode: str  # camera | sensor | both


class Hub:
    def __init__(self) -> None:
        self.clients: dict[WebSocket, Client] = {}

    async def add(self, ws: WebSocket, room_id: str | None, wake_mode: str) -> None:
        await ws.accept()
        self.clients[ws] = Client(room_id, wake_mode)

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
