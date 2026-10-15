import asyncio
import base64
import hmac
import json
import logging
import time
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, Field

from . import __version__, db, updates
from .config import settings
from .ha import ha
from .hub import hub
from .voice import pipeline, providers

logging.basicConfig(level=logging.INFO)

PAIR_TTL = 15 * 60  # s, so lange gilt ein Kopplungscode


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.conn()
    task = asyncio.create_task(ha.listen(hub.on_state_changed))
    yield
    task.cancel()


app = FastAPI(title="Hausgeist", version=__version__, lifespan=lifespan)


# ---------- Auth ----------
def admin(x_admin_key: str = Header("")):
    if settings.admin_key in ("", "change-me"):
        raise HTTPException(503, "ADMIN_KEY ist nicht gesetzt (Standardwert change-me ist gesperrt)")
    if not hmac.compare_digest(x_admin_key, settings.admin_key):
        raise HTTPException(401, "Admin-Key ungueltig")


def tablet(authorization: str = Header("")):
    row = db.tablet_by_token(authorization.removeprefix("Bearer ").strip())
    if not row:
        raise HTTPException(401, "Tablet-Token ungueltig")
    return row


def _can_access(entity_id: str, tab, is_admin: bool) -> bool:
    return is_admin or (tab and tab["room_id"] in db.rooms_for_entity(entity_id))


def _get(table: str, row_id: str):
    row = db.conn().execute(f"SELECT * FROM {table} WHERE id=?", (row_id,)).fetchone()
    if not row:
        raise HTTPException(404, "Nicht gefunden")
    return row


# ---------- Status (Admin) ----------
@app.get("/api/status", dependencies=[Depends(admin)])
async def status():
    """Ueberblick fuer die Admin-Oberflaeche."""
    def key(v: str) -> bool:
        return bool(v.strip())

    llm_ok = key(settings.xai_api_key) if settings.llm_provider == "xai" else key(settings.openai_api_key)
    tts_ok = (key(settings.elevenlabs_api_key) and key(settings.elevenlabs_voice_id)
              if settings.tts_provider == "elevenlabs" else key(settings.openai_api_key))
    entities = len(await ha.states()) if ha.connected else None
    return {
        "version": __version__,
        "ha": {"url": settings.ha_url, "connected": ha.connected, "token_set": key(settings.ha_token),
               "entities": entities},
        "voice": {"stt": settings.stt_provider, "llm": settings.llm_provider, "tts": settings.tts_provider,
                  "stt_ok": key(settings.openai_api_key), "llm_ok": llm_ok, "tts_ok": tts_ok},
        "tablets_online": len(hub.online()),
    }


# ---------- Raeume (Admin) ----------
class RoomIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    icon: str = "house"


class RoomPatch(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=60)
    icon: str | None = None


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


@app.patch("/api/rooms/{room_id}", dependencies=[Depends(admin)])
async def update_room(room_id: str, body: RoomPatch):
    _get("rooms", room_id)
    for col, val in body.model_dump(exclude_none=True).items():
        db.conn().execute(f"UPDATE rooms SET {col}=? WHERE id=?", (val, room_id))
    db.conn().commit()
    await hub.reload(room_id=room_id)


@app.delete("/api/rooms/{room_id}", dependencies=[Depends(admin)])
async def delete_room(room_id: str):
    await hub.reload(room_id=room_id)
    db.conn().execute("DELETE FROM rooms WHERE id=?", (room_id,))
    db.conn().commit()


@app.put("/api/rooms/{room_id}/entities", dependencies=[Depends(admin)])
async def set_room_entities(room_id: str, body: RoomEntities):
    _get("rooms", room_id)
    c = db.conn()
    c.execute("DELETE FROM room_entities WHERE room_id=?", (room_id,))
    c.executemany("INSERT OR IGNORE INTO room_entities VALUES(?,?)", [(room_id, e) for e in body.entity_ids])
    c.commit()
    await hub.reload(room_id=room_id)


class Presence(BaseModel):
    entity_id: str | None = None  # z. B. binary_sensor.wohnzimmer_praesenz


@app.put("/api/rooms/{room_id}/presence", dependencies=[Depends(admin)])
async def set_room_presence(room_id: str, body: Presence):
    """Praesenzmelder des Raums: meldet er Anwesenheit, wachen die Tablets im Raum auf."""
    _get("rooms", room_id)
    db.conn().execute("UPDATE rooms SET presence_entity=? WHERE id=?", (body.entity_id or None, room_id))
    db.conn().commit()
    await hub.reload(room_id=room_id)


@app.get("/api/entities", dependencies=[Depends(admin)])
async def all_entities():
    """Alle Home-Assistant-Geraete, zum Zuweisen zu Raeumen."""
    return await ha.states()


# ---------- Home-Assistant-Bereiche als Raeume uebernehmen ----------
async def _areas() -> list[dict]:
    try:
        return await ha.areas()
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, f"Home Assistant nicht erreichbar: {e}") from e


@app.get("/api/ha/areas", dependencies=[Depends(admin)])
async def ha_areas():
    linked = {r["ha_area_id"]: r["id"] for r in db.conn().execute(
        "SELECT id, ha_area_id FROM rooms WHERE ha_area_id IS NOT NULL")}
    return [a | {"room_id": linked.get(a["area_id"])} for a in await _areas()]


class AreaImport(BaseModel):
    area_ids: list[str] | None = None  # None = alle
    replace_entities: bool = False      # True: Geraeteliste ersetzen, sonst ergaenzen


@app.post("/api/rooms/import-areas", dependencies=[Depends(admin)])
async def import_areas(body: AreaImport):
    """Legt fuer HA-Bereiche Raeume an (oder aktualisiert die verknuepften) und weist die Geraete zu."""
    c = db.conn()
    created, updated = [], []
    # Praesenz-/Belegungsmelder eines Bereichs wird automatisch zum Weck-Sensor des Raums.
    presence_ids = {s["entity_id"] for s in await ha.states() if s["entity_id"].startswith("binary_sensor.")
                    and s["attributes"].get("device_class") in ("occupancy", "presence")}
    for a in await _areas():
        if body.area_ids is not None and a["area_id"] not in body.area_ids:
            continue
        row = c.execute("SELECT id FROM rooms WHERE ha_area_id=?", (a["area_id"],)).fetchone()
        if row is None:  # gleichnamiger Raum ohne Verknuepfung? Dann den nehmen.
            row = c.execute("SELECT id FROM rooms WHERE ha_area_id IS NULL AND lower(name)=lower(?)",
                            (a["name"],)).fetchone()
        if row:
            rid = row["id"]
            c.execute("UPDATE rooms SET ha_area_id=? WHERE id=?", (a["area_id"], rid))
            updated.append(a["name"])
        else:
            rid = db.new_id()
            c.execute("INSERT INTO rooms(id,name,icon,ha_area_id) VALUES(?,?,?,?)",
                      (rid, a["name"], "house", a["area_id"]))
            created.append(a["name"])
        if body.replace_entities:
            c.execute("DELETE FROM room_entities WHERE room_id=?", (rid,))
        c.executemany("INSERT OR IGNORE INTO room_entities VALUES(?,?)", [(rid, e) for e in a["entity_ids"]])
        sensors = [e for e in a["entity_ids"] if e in presence_ids]
        if len(sensors) == 1:
            c.execute("UPDATE rooms SET presence_entity=? WHERE id=? AND presence_entity IS NULL", (sensors[0], rid))
        await hub.reload(room_id=rid)
    c.commit()
    return {"created": created, "updated": updated}


# ---------- Tablets (Admin) ----------
class TabletIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    room_id: str | None = None


class TabletPatch(BaseModel):
    name: str | None = Field(None, min_length=1, max_length=60)
    room_id: str | None = None


def _new_pair_code(tablet_id: str) -> dict:
    code, expires = db.new_pair_code(), time.time() + PAIR_TTL
    db.conn().execute("UPDATE tablets SET pair_code=?, pair_expires=? WHERE id=?", (code, expires, tablet_id))
    db.conn().commit()
    return {"pair_code": code, "pair_expires": expires}


@app.post("/api/tablets", dependencies=[Depends(admin)])
def register_tablet(body: TabletIn):
    if body.room_id:
        _get("rooms", body.room_id)
    tid, token = db.new_id(), db.new_token()
    db.conn().execute("INSERT INTO tablets(id,name,room_id,token) VALUES(?,?,?,?)",
                      (tid, body.name, body.room_id, token))
    db.conn().commit()
    # Am Tablet entweder den Kopplungscode oder den Token eintragen.
    return {"id": tid, "token": token, **_new_pair_code(tid)}


@app.get("/api/tablets", dependencies=[Depends(admin)])
def list_tablets():
    online, now = hub.online(), time.time()
    out = []
    for r in db.conn().execute("SELECT * FROM tablets ORDER BY name"):
        t = dict(r)
        valid = t["pair_code"] and (t["pair_expires"] or 0) > now
        out.append(t | {"token": None, "display": display_settings(r), "online": t["id"] in online,
                        "pair_code": t["pair_code"] if valid else None,
                        "pair_expires": t["pair_expires"] if valid else None})
    return out


@app.patch("/api/tablets/{tablet_id}", dependencies=[Depends(admin)])
async def update_tablet(tablet_id: str, body: TabletPatch):
    _get("tablets", tablet_id)
    if body.room_id:
        _get("rooms", body.room_id)
    for col in body.model_fields_set:  # room_id=null heisst "keinem Raum zuweisen"
        db.conn().execute(f"UPDATE tablets SET {col}=? WHERE id=?", (getattr(body, col), tablet_id))
    db.conn().commit()
    await hub.reload(tablet_id=tablet_id)


@app.put("/api/tablets/{tablet_id}/room", dependencies=[Depends(admin)])
async def assign_tablet(tablet_id: str, room_id: str | None = None):
    await update_tablet(tablet_id, TabletPatch(room_id=room_id))


@app.delete("/api/tablets/{tablet_id}", dependencies=[Depends(admin)])
async def delete_tablet(tablet_id: str):
    await hub.reload(tablet_id=tablet_id)
    db.conn().execute("DELETE FROM tablets WHERE id=?", (tablet_id,))
    db.conn().commit()
    pipeline.forget(tablet_id)


@app.post("/api/tablets/{tablet_id}/pair", dependencies=[Depends(admin)])
def new_pair_code(tablet_id: str):
    _get("tablets", tablet_id)
    return _new_pair_code(tablet_id)


@app.post("/api/tablets/{tablet_id}/token", dependencies=[Depends(admin)])
async def rotate_token(tablet_id: str):
    """Neuer Token: das Tablet muss neu gekoppelt werden (z. B. wenn es weg ist)."""
    _get("tablets", tablet_id)
    token = db.new_token()
    db.conn().execute("UPDATE tablets SET token=? WHERE id=?", (token, tablet_id))
    db.conn().commit()
    await hub.reload(tablet_id=tablet_id)
    return {"token": token, **_new_pair_code(tablet_id)}


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
async def set_tablet_display(tablet_id: str, body: Display):
    _get("tablets", tablet_id)
    db.conn().execute("UPDATE tablets SET display=? WHERE id=?", (body.model_dump_json(), tablet_id))
    db.conn().commit()
    await hub.reload(tablet_id=tablet_id)


# ---------- Kopplung (Tablet, ohne Login) ----------
class PairIn(BaseModel):
    code: str


_pair_failures: dict[str, deque] = {}


@app.post("/api/pair")
def pair(body: PairIn, request: Request):
    """Tablet tauscht den 6-stelligen Code aus der Admin-Oberflaeche gegen seinen Token."""
    ip = request.client.host if request.client else "?"
    fails = _pair_failures.setdefault(ip, deque())
    while fails and fails[0] < time.time() - 300:
        fails.popleft()
    if len(fails) >= 10:
        raise HTTPException(429, "Zu viele Versuche, bitte 5 Minuten warten")
    code = "".join(ch for ch in body.code if ch.isdigit())
    row = db.conn().execute("SELECT * FROM tablets WHERE pair_code=? AND pair_expires>?",
                            (code, time.time())).fetchone() if len(code) == 6 else None
    if not row:
        fails.append(time.time())
        raise HTTPException(404, "Code ungueltig oder abgelaufen")
    db.conn().execute("UPDATE tablets SET pair_code=NULL, pair_expires=NULL WHERE id=?", (row["id"],))
    db.conn().commit()
    return {"token": row["token"], "tablet": row["name"]}


# ---------- Tablet-App ----------
@app.get("/api/me")
async def me(tab=Depends(tablet)):
    """Die Tablet-App holt hier ihren Raum und nur dessen Geraete."""
    room = db.conn().execute("SELECT * FROM rooms WHERE id=?", (tab["room_id"],)).fetchone()
    ids = set(db.room_entity_ids(tab["room_id"])) if room else set()
    states = [s for s in await ha.states() if s["entity_id"] in ids]
    return {"tablet": tab["name"], "room": dict(room) if room else None, "entities": states,
            "display": display_settings(tab), "server_version": __version__}


@app.get("/api/app/update")
async def app_update(_=Depends(tablet)):
    """Neueste veroeffentlichte App-Version (oder null, wenn die Pruefung aus ist)."""
    return await updates.latest()


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
async def ws_endpoint(ws: WebSocket, token: str = ""):
    # Token bevorzugt im Header (landet so nicht in Zugriffs-Logs); ?token= nur fuer App 0.1.x.
    header = ws.headers.get("authorization", "").removeprefix("Bearer ").strip()
    row = db.tablet_by_token(header or token)
    if not row:
        await ws.close(code=4401)
        return
    await hub.add(ws, row["id"], row["room_id"], display_settings(row)["wake_mode"])
    try:
        while True:
            await ws.receive_text()
    except WebSocketDisconnect:
        hub.remove(ws)


# ---------- Sprachassistent ----------
class VoiceText(BaseModel):
    text: str = Field(min_length=1, max_length=1000)


async def _voice(text: str, tab) -> dict:
    result = await pipeline.run(text, tab["room_id"], tab["id"])
    audio, mime = await providers.synthesize(result["reply"])
    return {**result, "audio_base64": base64.b64encode(audio).decode(), "mime": mime}


@app.post("/api/voice/text")
async def voice_text(body: VoiceText, tab=Depends(tablet)):
    return await _voice(body.text, tab)


@app.post("/api/voice/audio")
async def voice_audio(file: UploadFile, tab=Depends(tablet)):
    text = await providers.transcribe(await file.read(), file.filename or "audio.m4a")
    if not text.strip():
        return {"transcript": "", "reply": "Ich habe nichts verstanden.", "actions": []}
    return {"transcript": text, **await _voice(text, tab)}


@app.get("/health")
def health():
    return {"ok": True, "version": __version__, "ha_connected": ha.connected}


# ---------- Admin-Oberflaeche ----------
@app.get("/", include_in_schema=False)
def root():
    return RedirectResponse("/admin/")


app.mount("/admin", StaticFiles(directory=Path(__file__).parent / "admin", html=True), name="admin")
