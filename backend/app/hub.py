"""Verwaltet WebSocket-Verbindungen der Tablets und verteilt Live-Updates raumgefiltert."""
import asyncio
import time
from collections.abc import Callable
from dataclasses import dataclass, field

from fastapi import WebSocket

from . import db

# Zustaende, bei denen ein Praesenz-/Bewegungsmelder "jemand ist da" meldet
PRESENT_STATES = {"on", "home", "detected"}
WAKE_WINDOW = 0.35  # s, so lange sammelt der Server Meldungen anderer Tablets zum selben Ruf
WAKE_LATE = 2.0     # s, spaetere Meldungen gehoeren noch zum entschiedenen Ruf


@dataclass
class Client:
    tablet_id: str
    room_id: str | None
    wake_mode: str  # camera | sensor | both
    voice_wake: bool = False  # hoert auf das Aktivierungswort


@dataclass
class Candidate:
    ws: WebSocket
    client: Client
    id: str
    level: float      # Lautstaerke des Rufs in dBFS (-100..0), naeher = lauter
    presence: bool    # Kamera hat gerade jemanden gesehen
    near: bool        # Kamera: jemand steht direkt davor


@dataclass
class _Round:
    candidates: list[Candidate] = field(default_factory=list)
    decided: float | None = None
    timer: asyncio.Task | None = None


class Hub:
    def __init__(self, window: float = WAKE_WINDOW) -> None:
        self.clients: dict[WebSocket, Client] = {}
        self.window = window
        # Raum gerade besetzt laut Praesenzmelder in Home Assistant (setzt main)
        self.occupied: Callable[[str | None], bool] = lambda room_id: False
        self._round: _Round | None = None

    async def add(self, ws: WebSocket, tablet_id: str, room_id: str | None, wake_mode: str,
                  voice_wake: bool = False) -> None:
        await ws.accept()
        self.clients[ws] = Client(tablet_id, room_id, wake_mode, voice_wake)

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

    async def reload_all(self) -> None:
        for ws in list(self.clients):
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

    # ---------- Aktivierungswort: nur ein Tablet antwortet ----------
    async def on_message(self, ws: WebSocket, msg: dict) -> None:
        if msg.get("type") == "wake_heard" and ws in self.clients:
            await self.wake_heard(ws, msg)

    async def wake_heard(self, ws: WebSocket, msg: dict) -> None:
        """Ein Tablet hat das Aktivierungswort gehoert. Alle Tablets, die denselben Ruf melden,
        werden kurz gesammelt; antworten darf nur das, bei dem jemand ist bzw. das am lautesten hoerte."""
        try:
            level = max(-100.0, min(0.0, float(msg.get("level", -100))))
        except (TypeError, ValueError):
            level = -100.0
        cand = Candidate(ws, self.clients[ws], str(msg.get("id", ""))[:64], level,
                         bool(msg.get("presence")), bool(msg.get("near")))
        r = self._round
        if r and r.decided is not None and time.monotonic() - r.decided < WAKE_LATE:
            await self._result(cand, False)  # zu spaet, ein anderes Tablet hoert schon zu
            return
        if r is None or r.decided is not None:
            r = self._round = _Round()
            listeners = sum(1 for c in self.clients.values() if c.voice_wake)
            r.candidates.append(cand)
            if listeners <= 1:
                await self._decide(r)
            else:
                r.timer = asyncio.create_task(self._decide_later(r))
            return
        r.candidates.append(cand)
        if len(r.candidates) >= sum(1 for c in self.clients.values() if c.voice_wake):
            await self._decide(r)  # alle haben gemeldet, nicht laenger warten

    def _rank(self, c: Candidate) -> tuple:
        here = c.presence or c.near or self.occupied(c.client.room_id)
        return (here, c.near, c.level)

    async def _decide_later(self, r: _Round) -> None:
        await asyncio.sleep(self.window)
        await self._decide(r)

    async def _decide(self, r: _Round) -> None:
        if r.decided is not None:
            return
        r.decided = time.monotonic()
        alive = [c for c in r.candidates if c.ws in self.clients]
        if not alive:
            return
        winner = max(alive, key=self._rank)
        for c in alive:
            await self._result(c, c is winner)

    async def _result(self, c: Candidate, accept: bool) -> None:
        await self._send(c.ws, {"type": "wake_result", "id": c.id, "accept": accept})


hub = Hub()
