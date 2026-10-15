import asyncio
import base64
import hmac
import json
import logging
from contextlib import asynccontextmanager

from fastapi import Depends, FastAPI, Header, HTTPException, UploadFile, WebSocket, WebSocketDisconnect
from typing import Literal

from pydantic import BaseModel, Field

from . import db
from .config import settings
from .ha import ha
from .hub import hub
from .voice import pipeline, providers

logging.basicConfig(level=logging.INFO)


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.conn()
    task = asyncio.create_task(ha.listen(hub.on_state_changed))
    yield
    task.cancel()


app = FastAPI(title="Hausgeist", version="0.1.0", lifespan=lifespan)


# ---------- Auth ----------
def admin(x_admin_key: str = Header("")):
    if settings.admin_key in ("", "change-me"):
        raise HTTPException(503, "ADMIN_KEY ist nicht gesetzt (Standardwert change-me ist gesperrt)")
    if not hmac.compare_digest(x_admin_key, settings.admin_key):
        raise HTTPException(401, "Admin-Key ungueltig")


def tablet(authorization: str = Header("")):
    token = authorization.removeprefix("Bearer ").strip()
    row = db.conn().execute("SELECT * FROM tablets WHERE token=?", (token,)).fetchone()
    if not row:
        raise HTTPException(401, "Tablet-Token ungueltig")
    return row


def _can_access(entity_id: str, tab, is_admin: bool) -> bool:
    return is_admin or (tab and tab["room_id"] in db.rooms_for_entity(entity_id))


# ---------- Raeume (Admin) ----------
class RoomIn(BaseModel):
    name: str
    icon: str = "house"


class RoomEntities(BaseModel):
    entity_ids: list[str]


@app.get("/api/rooms", dependencies=[Depends(admin)])
def list_rooms():
    rooms = [dict(r) for r in db.conn().execute("SELECT * FROM rooms ORDER BY name")]
    for r in rooms:
        r["entity_ids"] = db.room_entity_ids(r["id"])
    return rooms


@app.post("/api/rooms", dependencies=[Depends(admin)])
def create_room(body: RoomIn):
    rid = db.new_id()
    db.conn().execute("INSERT INTO rooms(id,name,icon) VALUES(?,?,?)", (rid, body.name, body.icon))
    db.conn().commit()
    return {"id": rid, **body.model_dump()}


@app.delete("/api/rooms/{room_id}", dependencies=[Depends(admin)])
def delete_room(room_id: str):
    db.conn().execute("DELETE FROM rooms WHERE id=?", (room_id,))
    db.conn().commit()


@app.put("/api/rooms/{room_id}/entities", dependencies=[Depends(admin)])
def set_room_entities(room_id: str, body: RoomEntities):
    c = db.conn()
    c.execute("DELETE FROM room_entities WHERE room_id=?", (room_id,))
    c.executemany("INSERT INTO room_entities VALUES(?,?)", [(room_id, e) for e in body.entity_ids])
    c.commit()


class Presence(BaseModel):
    entity_id: str | None = None  # z. B. binary_sensor.wohnzimmer_praesenz


@app.put("/api/rooms/{room_id}/presence", dependencies=[Depends(admin)])
def set_room_presence(room_id: str, body: Presence):
    """Praesenzmelder des Raums: meldet er Anwesenheit, wachen die Tablets im Raum auf."""
    db.conn().execute("UPDATE rooms SET presence_entity=? WHERE id=?", (body.entity_id, room_id))
    db.conn().commit()


@app.get("/api/entities", dependencies=[Depends(admin)])
async def all_entities():
    """Alle Home-Assistant-Geraete, zum Zuweisen zu Raeumen."""
    return await ha.states()


# ---------- Tablets ----------
class TabletIn(BaseModel):
    name: str
    room_id: str | None = None


@app.post("/api/tablets", dependencies=[Depends(admin)])
def register_tablet(body: TabletIn):
    tid, token = db.new_id(), db.new_token()
    db.conn().execute("INSERT INTO tablets(id,name,room_id,token) VALUES(?,?,?,?)",
                      (tid, body.name, body.room_id, token))
    db.conn().commit()
    return {"id": tid, "token": token}  # Token einmalig in die Tablet-App eintragen


@app.get("/api/tablets", dependencies=[Depends(admin)])
def list_tablets():
    return [dict(r) | {"token": None} for r in db.conn().execute("SELECT * FROM tablets")]


@app.put("/api/tablets/{tablet_id}/room", dependencies=[Depends(admin)])
def assign_tablet(tablet_id: str, room_id: str | None = None):
    db.conn().execute("UPDATE tablets SET room_id=? WHERE id=?", (room_id, tablet_id))
    db.conn().commit()


class Display(BaseModel):
    """Display-Verhalten eines Wandtablets. Die App wertet das lokal aus (DisplayController)."""
    wake_mode: Literal["camera", "sensor", "both"] = "both"
    dim_after: int = Field(30, ge=5, le=3600)       # s ohne Beruehrung -> gedimmt (Raum besetzt)
    sleep_after: int = Field(120, ge=10, le=7200)   # s ohne Beruehrung und ohne Person -> schwarz
    presence_hold: int = Field(90, ge=10, le=3600)  # s, die der Raum nach letzter Bewegung besetzt gilt
    near_motion_area: float = Field(0.2, ge=0.01, le=1)  # Bildanteil, ab dem Bewegung = Annaeherung
    min_brightness: float = Field(0.02, ge=0, le=1)
    max_brightness: float = Field(1.0, ge=0, le=1)
    idle_factor: float = Field(0.35, ge=0, le=1)    # gedimmt = Zielhelligkeit * Faktor
    night_start: int = Field(22, ge=0, le=23)
    night_end: int = Field(6, ge=0, le=23)
    night_max_brightness: float = Field(0.15, ge=0, le=1)


def display_settings(tab) -> dict:
    return Display(**json.loads(tab["display"] or "{}")).model_dump()


@app.put("/api/tablets/{tablet_id}/display", dependencies=[Depends(admin)])
def set_tablet_display(tablet_id: str, body: Display):
    db.conn().execute("UPDATE tablets SET display=? WHERE id=?", (body.model_dump_json(), tablet_id))
    db.conn().commit()


@app.get("/api/me")
async def me(tab=Depends(tablet)):
    """Die Tablet-App holt hier ihren Raum und nur dessen Geraete."""
    room = db.conn().execute("SELECT * FROM rooms WHERE id=?", (tab["room_id"],)).fetchone()
    ids = set(db.room_entity_ids(tab["room_id"])) if room else set()
    states = [s for s in await ha.states() if s["entity_id"] in ids]
    return {"tablet": tab["name"], "room": dict(room) if room else None, "entities": states,
            "display": display_settings(tab)}


# ---------- Steuerung ----------
class Command(BaseModel):
    action: str
    value: float | str | None = None   # str z. B. fuer hvac_mode / fan_mode
    data: dict | None = None           # z. B. {"hs_color": [30, 80]} oder {"color_temp_kelvin": 2700}


@app.post("/api/entities/{entity_id}/command")
async def command(entity_id: str, body: Command, tab=Depends(tablet)):
    if not _can_access(entity_id, tab, False):
        raise HTTPException(403, "Geraet gehoert nicht zu diesem Raum")
    try:
        await ha.command(entity_id, body.action, body.value, body.data)
    except ValueError as e:
        raise HTTPException(400, str(e)) from e


@app.websocket("/ws")
async def ws_endpoint(ws: WebSocket, token: str):
    row = db.conn().execute("SELECT * FROM tablets WHERE token=?", (token,)).fetchone()
    if not row:
        await ws.close(code=4401)
        return
    await hub.add(ws, row["room_id"], display_settings(row)["wake_mode"])
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        hub.remove(ws)


# ---------- Sprachassistent ----------
class VoiceText(BaseModel):
    text: str


@app.post("/api/voice/text")
async def voice_text(body: VoiceText, tab=Depends(tablet)):
    result = await pipeline.run(body.text, tab["room_id"])
    audio, mime = await providers.synthesize(result["reply"])
    return {**result, "audio_base64": base64.b64encode(audio).decode(), "mime": mime}


@app.post("/api/voice/audio")
async def voice_audio(file: UploadFile, tab=Depends(tablet)):
    text = await providers.transcribe(await file.read(), file.filename or "audio.m4a")
    result = await pipeline.run(text, tab["room_id"])
    audio, mime = await providers.synthesize(result["reply"])
    return {"transcript": text, **result,
            "audio_base64": base64.b64encode(audio).decode(), "mime": mime}


@app.get("/health")
def health():
    return {"ok": True}
