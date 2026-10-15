import asyncio
import base64
import json
import logging
import time
from collections import deque
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Literal

from fastapi import Depends, FastAPI, Header, HTTPException, Request, UploadFile, WebSocket, WebSocketDisconnect
from fastapi.responses import JSONResponse, RedirectResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel, ConfigDict, Field, field_validator

from . import __version__, auth, config, db, updates
from .config import EDITABLE, settings
from .ha import ha
from .hub import hub
from .voice import pipeline, providers

logging.basicConfig(level=logging.INFO)

PAIR_TTL = 15 * 60  # s, so lange gilt ein Kopplungscode


@asynccontextmanager
async def lifespan(_: FastAPI):
    db.conn()
    config.apply(db.get_settings())
    await ha.reconfigure()
    task = asyncio.create_task(ha.listen(hub.on_state_changed))
    yield
    task.cancel()


app = FastAPI(title="Hausgeist", version=__version__, lifespan=lifespan)


# ---------- Auth ----------
def admin(x_admin_key: str = Header("")) -> str:
    """Sitzungs-Token aus der Anmeldung oder ADMIN_KEY. Gibt den benutzten Schluessel zurueck."""
    if not auth.configured():
        raise HTTPException(503, "Noch nicht eingerichtet: bitte zuerst in /admin ein Passwort festlegen")
    if not auth.check(x_admin_key):
        raise HTTPException(401, "Nicht angemeldet oder Anmeldung abgelaufen")
    return x_admin_key


_failures: dict[str, dict[str, deque]] = {"pair": {}, "login": {}}


def _throttle(kind: str, request: Request) -> deque:
    """Hoechstens 10 Fehlversuche je IP in 5 Minuten (Kopplungscodes, Passwort)."""
    ip = request.client.host if request.client else "?"
    fails = _failures[kind].setdefault(ip, deque())
    while fails and fails[0] < time.time() - 300:
        fails.popleft()
    if len(fails) >= 10:
        raise HTTPException(429, "Zu viele Versuche, bitte 5 Minuten warten")
    return fails


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
    entities = len(await ha.states()) if ha.connected else None
    return {
        "version": __version__,
        "ha": {"url": settings.ha_url, "connected": ha.connected, "token_set": bool(settings.ha_token.strip()),
               "entities": entities, "error": None if ha.connected else ha.last_error},
        "voice": {"stt": settings.stt_provider, "llm": settings.llm_provider, "tts": settings.tts_provider,
                  "stt_ok": providers.stt_ready(settings), "llm_ok": providers.llm_ready(settings),
                  "tts_ok": providers.tts_ready(settings)},
        "tablets_online": len(hub.online()),
        "password_set": auth.has_password(),
    }


# ---------- Ersteinrichtung und Anmeldung ----------
class PasswordIn(BaseModel):
    password: str = Field(min_length=auth.MIN_PASSWORD, max_length=200)


class LoginIn(BaseModel):
    password: str = Field(max_length=200)


class PasswordChange(BaseModel):
    current: str = Field(max_length=200)
    new: str = Field(min_length=auth.MIN_PASSWORD, max_length=200)


@app.get("/api/setup")
def setup_state():
    """Ohne Anmeldung: muss die Verwaltung erst eingerichtet werden?"""
    return {"needs_setup": not auth.configured(), "version": __version__}


@app.post("/api/setup")
def setup(body: PasswordIn):
    """Erster Aufruf: Passwort fuer die Verwaltung festlegen. Danach gesperrt."""
    if auth.configured():
        raise HTTPException(409, "Hausgeist ist schon eingerichtet")
    auth.set_password(body.password)
    return {"token": auth.new_session()}


@app.post("/api/admin/login")
def login(body: LoginIn, request: Request):
    if not auth.configured():
        raise HTTPException(503, "Noch nicht eingerichtet")
    fails = _throttle("login", request)
    if not auth.check_password(body.password):
        fails.append(time.time())
        raise HTTPException(401, "Passwort falsch")
    return {"token": auth.new_session()}


@app.post("/api/admin/logout")
def logout(key: str = Depends(admin)):
    auth.end_session(key)


@app.put("/api/admin/password")
def change_password(body: PasswordChange, request: Request, key: str = Depends(admin)):
    """Neues Passwort; alle anderen Anmeldungen werden beendet."""
    fails = _throttle("login", request)
    if not auth.check_password(body.current):
        fails.append(time.time())
        raise HTTPException(403, "Das bisherige Passwort stimmt nicht")
    auth.set_password(body.new)
    auth.end_other_sessions(key)


# ---------- Einstellungen (Admin) ----------
HTTP_URL = r"^https?://[^\s/]+(:\d+)?(/.*)?$"


class SettingsPatch(BaseModel):
    """Nur mitgeschickte Felder werden geaendert. null = gespeicherten Wert loeschen (Container-Wert gilt)."""
    model_config = ConfigDict(extra="forbid")

    ha_url: str | None = Field(None, pattern=HTTP_URL, max_length=300)
    ha_token: str | None = Field(None, max_length=1000)
    openai_api_key: str | None = Field(None, max_length=500)
    xai_api_key: str | None = Field(None, max_length=500)
    elevenlabs_api_key: str | None = Field(None, max_length=500)
    elevenlabs_voice_id: str | None = Field(None, max_length=100)
    elevenlabs_model: str | None = Field(None, max_length=100)
    stt_provider: Literal["openai"] | None = None
    stt_model: str | None = Field(None, max_length=100)
    stt_language: str | None = Field(None, pattern=r"^([a-z]{2})?$")
    llm_provider: Literal["openai", "xai", "custom"] | None = None
    openai_llm_model: str | None = Field(None, max_length=100)
    xai_llm_model: str | None = Field(None, max_length=100)
    custom_llm_url: str | None = Field(None, pattern=r"^$|" + HTTP_URL, max_length=300)
    custom_llm_api_key: str | None = Field(None, max_length=500)
    custom_llm_model: str | None = Field(None, max_length=100)
    tts_provider: Literal["elevenlabs", "openai"] | None = None
    openai_tts_model: str | None = Field(None, max_length=100)
    openai_tts_voice: str | None = Field(None, max_length=50)
    assistant_instructions: str | None = Field(None, max_length=4000)
    update_repo: str | None = Field(None, pattern=r"^$|^[\w.-]+/[\w.-]+$", max_length=200)

    @field_validator("*", mode="before")
    @classmethod
    def _strip(cls, v):
        return v.strip() if isinstance(v, str) else v

    def changes(self) -> dict[str, str | None]:
        return {k: getattr(self, k) for k in self.model_fields_set}


def _settings_view() -> dict:
    stored = db.get_settings()
    out = {}
    for key, secret in EDITABLE.items():
        value = getattr(settings, key)
        out[key] = {"value": None if secret else value, "secret": secret, "set": bool(str(value).strip()),
                    "source": config.source(key, stored),
                    "default": None if secret else getattr(config.env_settings, key)}
    return out


@app.get("/api/settings", dependencies=[Depends(admin)])
def get_settings():
    """Alle in der Verwaltung aenderbaren Einstellungen. Schluessel werden nie zurueckgegeben."""
    return _settings_view()


@app.put("/api/settings", dependencies=[Depends(admin)])
async def put_settings(body: SettingsPatch):
    changes = body.changes()
    db.put_settings(changes)
    config.apply(db.get_settings())
    if {"ha_url", "ha_token"} & changes.keys():
        await ha.reconfigure()
    if "update_repo" in changes:
        updates.clear()
    return _settings_view()


def _preview(body: SettingsPatch) -> config.Settings:
    """Aktuelle Einstellungen mit ungespeicherten Werten aus dem Formular (null/leer = aktueller Wert)."""
    return settings.model_copy(update={k: v for k, v in body.changes().items() if v not in (None, "")})


def _error(e: Exception) -> str:
    status = getattr(getattr(e, "response", None), "status_code", None) or getattr(e, "status_code", None)
    if status in (401, 403):
        return "Der Schlüssel wird abgelehnt."
    if status == 404:
        return "Nicht gefunden (Modell, Stimme oder Adresse prüfen)."
    if status == 429:
        return "Zu viele Anfragen oder kein Guthaben mehr."
    text = str(e).strip() or type(e).__name__
    return text[:300]


@app.post("/api/settings/test/{kind}", dependencies=[Depends(admin)])
async def test_settings(kind: Literal["ha", "llm", "stt", "tts", "voices"], body: SettingsPatch):
    """Probiert eine Verbindung mit den Werten aus dem Formular aus, ohne zu speichern."""
    cfg = _preview(body)
    try:
        if kind == "ha":
            return await ha.probe(cfg.ha_url, cfg.ha_token)
        if kind == "llm":
            if not providers.llm_ready(cfg):
                return {"ok": False, "message": "Schlüssel, Adresse oder Modell fehlt."}
            client, model = providers.llm_client(cfg)
            start = time.monotonic()
            res = await client.chat.completions.create(
                model=model, max_tokens=20,
                messages=[{"role": "user", "content": "Antworte nur mit: Hallo, ich bin bereit."}])
            ms = round((time.monotonic() - start) * 1000)
            return {"ok": True, "message": f"{model} antwortet in {ms} ms: „{(res.choices[0].message.content or '').strip()}“"}
        if kind == "stt":
            if not providers.stt_ready(cfg):
                return {"ok": False, "message": "Es fehlt der OpenAI-Schlüssel."}
            client = providers.AsyncOpenAI(api_key=cfg.openai_api_key)
            await client.models.retrieve(cfg.stt_model)
            return {"ok": True, "message": f"Schlüssel gültig, Modell {cfg.stt_model} verfügbar."}
        if kind == "voices":
            if not cfg.elevenlabs_api_key.strip():
                return {"ok": False, "message": "Es fehlt der ElevenLabs-Schlüssel.", "voices": []}
            voices = await providers.elevenlabs_voices(cfg)
            return {"ok": True, "message": f"{len(voices)} Stimmen gefunden.", "voices": voices}
        if not providers.tts_ready(cfg):
            return {"ok": False, "message": "Schlüssel oder Stimme fehlt."}
        audio, mime = await providers.synthesize("Hallo, ich bin Hausgeist. So klinge ich.", cfg)
        return {"ok": True, "message": "Stimme funktioniert.", "audio_base64": base64.b64encode(audio).decode(),
                "mime": mime}
    except Exception as e:  # noqa: BLE001
        return {"ok": False, "message": _error(e)}


class VoiceTest(BaseModel):
    text: str = Field(min_length=1, max_length=1000)
    room_id: str | None = None
    speak: bool = True


@app.post("/api/voice/test", dependencies=[Depends(admin)])
async def voice_test(body: VoiceTest):
    """Sprachassistent aus der Verwaltung ausprobieren, als stuende man im gewaehlten Raum."""
    if body.room_id:
        _get("rooms", body.room_id)
    try:
        result = await pipeline.run(body.text, body.room_id, f"admin:{body.room_id}")
        if body.speak and providers.tts_ready(settings):
            audio, mime = await providers.synthesize(result["reply"])
            result |= {"audio_base64": base64.b64encode(audio).decode(), "mime": mime}
    except Exception as e:  # noqa: BLE001
        raise HTTPException(502, f"Sprachdienst: {_error(e)}") from e
    return result


# ---------- Sicherung (Admin) ----------
BACKUP_COLUMNS = {
    "rooms": ["id", "name", "icon", "presence_entity", "ha_area_id"],
    "room_entities": ["room_id", "entity_id"],
    "tablets": ["id", "name", "room_id", "token", "display"],
}


class Backup(BaseModel):
    format: Literal["hausgeist-backup"]
    settings: dict[str, str] = {}
    rooms: list[dict] = []
    room_entities: list[dict] = []
    tablets: list[dict] = []


@app.get("/api/backup", dependencies=[Depends(admin)])
def export_backup():
    """Raeume, Tablets (mit Tokens) und Einstellungen (mit Schluesseln) als JSON. Ohne Passwort."""
    c = db.conn()
    data = {"format": "hausgeist-backup", "version": __version__, "created": time.strftime("%Y-%m-%dT%H:%M:%S"),
            "settings": db.get_settings()}
    for table, cols in BACKUP_COLUMNS.items():
        data[table] = [dict(r) for r in c.execute(f"SELECT {', '.join(cols)} FROM {table}")]
    name = f"hausgeist-sicherung-{time.strftime('%Y-%m-%d')}.json"
    return JSONResponse(data, headers={"Content-Disposition": f'attachment; filename="{name}"'})


@app.post("/api/backup", dependencies=[Depends(admin)])
async def import_backup(body: Backup):
    """Ersetzt Raeume, Tablets und gespeicherte Einstellungen durch die Sicherung."""
    try:
        values = SettingsPatch(**{k: v for k, v in body.settings.items() if k in EDITABLE}).changes()
    except ValueError as e:
        raise HTTPException(422, f"Ungueltige Einstellung in der Sicherung: {e}") from e
    c = db.conn()
    try:
        c.execute("DELETE FROM tablets")
        c.execute("DELETE FROM rooms")
        c.execute("DELETE FROM settings WHERE substr(key, 1, 1) != '_'")
        for table, cols in BACKUP_COLUMNS.items():
            for row in getattr(body, table):
                if not all(row.get(k) is not None for k in cols[:2]):
                    raise ValueError(f"{table}: Eintrag ohne {cols[0]}/{cols[1]}")
                c.execute(f"INSERT OR IGNORE INTO {table}({', '.join(cols)}) VALUES({', '.join('?' * len(cols))})",
                          [row.get(k) if k != "display" else (row.get(k) or "{}") for k in cols])
        c.executemany("INSERT INTO settings(key, value) VALUES(?, ?)", [(k, v) for k, v in values.items() if v is not None])
        c.commit()
    except (ValueError, db.sqlite3.Error) as e:
        c.rollback()
        raise HTTPException(422, f"Sicherung ist unvollstaendig: {e}") from e
    config.apply(db.get_settings())
    await ha.reconfigure()
    await hub.reload_all()
    return {"rooms": len(body.rooms), "tablets": len(body.tablets)}


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


@app.post("/api/pair")
def pair(body: PairIn, request: Request):
    """Tablet tauscht den 6-stelligen Code aus der Admin-Oberflaeche gegen seinen Token."""
    fails = _throttle("pair", request)
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


class AdminFiles(StaticFiles):
    """Immer per ETag nachfragen, sonst laeuft nach einem Update noch die alte Verwaltung im Browser."""

    def file_response(self, *args, **kwargs):
        response = super().file_response(*args, **kwargs)
        response.headers["Cache-Control"] = "no-cache"
        return response


app.mount("/admin", AdminFiles(directory=Path(__file__).parent / "admin", html=True), name="admin")
