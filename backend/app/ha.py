"""Home Assistant Client: REST fuer Zustaende/Services, WebSocket fuer Live-Events."""
import asyncio
import json
import logging
from collections.abc import Awaitable, Callable

import httpx
import websockets

from .config import settings

log = logging.getLogger("ha")

# Nur diese Domains werden in der App angezeigt/gesteuert.
SUPPORTED_DOMAINS = {"light", "switch", "climate", "cover", "fan", "media_player", "sensor",
                     "binary_sensor", "lock", "scene", "input_boolean"}

# (domain, action) -> HA-Service
ACTION_SERVICES = {
    ("light", "on"): "turn_on", ("light", "off"): "turn_off",
    ("switch", "on"): "turn_on", ("switch", "off"): "turn_off",
    ("fan", "on"): "turn_on", ("fan", "off"): "turn_off",
    ("input_boolean", "on"): "turn_on", ("input_boolean", "off"): "turn_off",
    ("climate", "set_temperature"): "set_temperature",
    ("climate", "set_mode"): "set_hvac_mode",
    ("climate", "on"): "turn_on", ("climate", "off"): "turn_off",
    ("climate", "set_fan_mode"): "set_fan_mode",
    ("climate", "set_swing_mode"): "set_swing_mode",
    ("climate", "set_preset"): "set_preset_mode",
    ("cover", "open"): "open_cover", ("cover", "close"): "close_cover",
    ("cover", "set_position"): "set_cover_position",
    ("media_player", "play_pause"): "media_play_pause",
    ("media_player", "set_volume"): "volume_set",
    ("media_player", "next"): "media_next_track",
    ("media_player", "previous"): "media_previous_track",
    ("lock", "lock"): "lock", ("lock", "unlock"): "unlock",
    ("scene", "activate"): "turn_on",
}

# Zusaetzliche Felder, die die App mitschicken darf (z. B. Farbe beim Licht).
EXTRA_KEYS = {"hs_color", "color_temp_kelvin", "brightness_pct"}


def _service_data(domain: str, action: str, value, extra: dict | None = None) -> dict:
    data = {k: v for k, v in (extra or {}).items() if k in EXTRA_KEYS and domain == "light"}
    return data | _value_data(domain, action, value)


def _value_data(domain: str, action: str, value) -> dict:
    if value is None:
        return {}
    if domain == "light" and action == "on":
        return {"brightness_pct": int(value)}
    if action == "set_fan_mode":
        return {"fan_mode": str(value)}
    if action == "set_swing_mode":
        return {"swing_mode": str(value)}
    if action == "set_preset":
        return {"preset_mode": str(value)}
    if action == "set_temperature":
        return {"temperature": float(value)}
    if action == "set_mode":
        return {"hvac_mode": str(value)}
    if action == "set_position":
        return {"position": int(value)}
    if action == "set_volume":
        return {"volume_level": float(value)}
    return {}


class HomeAssistant:
    def __init__(self) -> None:
        self.http = self._client()
        # Spiegel der HA-Zustaende, gefuettert vom WebSocket. Nur gueltig, solange verbunden.
        self._cache: dict[str, dict] = {}
        self.connected = False
        self.last_error: str | None = None
        self._kick = asyncio.Event()  # weckt die Verbindungsschleife nach einer Konfig-Aenderung
        self._ws = None

    @staticmethod
    def _client(url: str | None = None, token: str | None = None) -> httpx.AsyncClient:
        return httpx.AsyncClient(
            base_url=(url if url is not None else settings.ha_url).rstrip("/"),
            headers={"Authorization": f"Bearer {token if token is not None else settings.ha_token}"},
            timeout=10,
        )

    async def reconfigure(self) -> None:
        """Adresse oder Token wurden in der Verwaltung geaendert: sofort neu verbinden."""
        old, self.http = self.http, self._client()
        self.connected = False
        self._kick.set()
        if self._ws is not None:
            await self._ws.close()
        await old.aclose()

    async def _pause(self, seconds: float) -> None:
        try:
            await asyncio.wait_for(self._kick.wait(), seconds)
        except TimeoutError:
            pass
        self._kick.clear()

    @staticmethod
    async def probe(url: str, token: str) -> dict:
        """Verbindung mit (evtl. noch nicht gespeicherten) Zugangsdaten pruefen."""
        if not token.strip():
            return {"ok": False, "message": "Es ist kein Zugriffstoken eingetragen."}
        try:
            async with HomeAssistant._client(url, token) as http:
                r = await http.get("/api/")
                if r.status_code == 401:
                    return {"ok": False, "message": "Home Assistant lehnt den Token ab."}
                r.raise_for_status()
                cfg = (await http.get("/api/config")).json()
                states = (await http.get("/api/states")).json()
        except httpx.HTTPError as e:
            return {"ok": False, "message": f"Home Assistant ist unter {url} nicht erreichbar ({type(e).__name__})."}
        except ValueError:
            return {"ok": False, "message": "Unter dieser Adresse antwortet kein Home Assistant."}
        n = sum(1 for s in states if s["entity_id"].split(".")[0] in SUPPORTED_DOMAINS)
        return {"ok": True, "message": f"Verbunden mit {cfg.get('location_name') or 'Home Assistant'} "
                                       f"(Version {cfg.get('version', '?')}, {n} Geräte).", "entities": n}

    @property
    def ws_url(self) -> str:
        return settings.ha_url.rstrip("/").replace("http", "ws", 1) + "/api/websocket"

    async def _fetch_states(self) -> list[dict]:
        r = await self.http.get("/api/states")
        r.raise_for_status()
        return [s for s in r.json() if s["entity_id"].split(".")[0] in SUPPORTED_DOMAINS]

    async def states(self) -> list[dict]:
        if self.connected:
            return list(self._cache.values())
        return await self._fetch_states()

    async def state(self, entity_id: str) -> dict:
        r = await self.http.get(f"/api/states/{entity_id}")
        r.raise_for_status()
        return r.json()

    async def command(self, entity_id: str, action: str, value=None, extra: dict | None = None) -> None:
        domain = entity_id.split(".")[0]
        if domain not in SUPPORTED_DOMAINS:
            raise ValueError(f"Domain nicht unterstuetzt: {domain}")
        service = ACTION_SERVICES.get((domain, action))
        if not service:
            raise ValueError(f"Aktion '{action}' fuer {domain} nicht unterstuetzt")
        data = {"entity_id": entity_id, **_service_data(domain, action, value, extra)}
        r = await self.http.post(f"/api/services/{domain}/{service}", json=data)
        r.raise_for_status()

    async def _auth(self, ws) -> bool:
        await ws.recv()  # auth_required
        await ws.send(json.dumps({"type": "auth", "access_token": settings.ha_token}))
        return json.loads(await ws.recv()).get("type") == "auth_ok"

    async def ws_call(self, *types: str) -> list:
        """Einmalige WebSocket-Abfragen, z. B. config/area_registry/list. Ergebnisse in Reihenfolge."""
        async with websockets.connect(self.ws_url, max_size=None) as ws:
            if not await self._auth(ws):
                raise RuntimeError("Home Assistant lehnt den Token ab")
            out = []
            for i, t in enumerate(types, start=1):
                await ws.send(json.dumps({"id": i, "type": t}))
                while True:
                    msg = json.loads(await ws.recv())
                    if msg.get("id") == i and msg.get("type") == "result":
                        break
                if not msg.get("success"):
                    raise RuntimeError(f"{t}: {msg.get('error', {}).get('message', 'Fehler')}")
                out.append(msg["result"])
            return out

    async def areas(self) -> list[dict]:
        """HA-Bereiche mit den unterstuetzten Entitaeten darin (direkt oder ueber das Geraet)."""
        areas, entities, devices = await self.ws_call(
            "config/area_registry/list", "config/entity_registry/list", "config/device_registry/list")
        device_area = {d["id"]: d.get("area_id") for d in devices}
        by_area: dict[str, list[str]] = {a["area_id"]: [] for a in areas}
        for e in entities:
            if e.get("disabled_by") or e.get("hidden_by"):
                continue
            if e["entity_id"].split(".")[0] not in SUPPORTED_DOMAINS:
                continue
            area = e.get("area_id") or device_area.get(e.get("device_id"))
            if area in by_area:
                by_area[area].append(e["entity_id"])
        return [{"area_id": a["area_id"], "name": a["name"], "icon": a.get("icon"),
                 "entity_ids": sorted(by_area[a["area_id"]])} for a in areas]

    async def listen(self, on_state_changed: Callable[[dict], Awaitable[None]]) -> None:
        """Dauerhaft state_changed-Events empfangen, mit Reconnect."""
        while True:
            if not settings.ha_token.strip():
                self.last_error = "Kein Zugriffstoken eingetragen"
                await self._pause(3600)
                continue
            try:
                async with websockets.connect(self.ws_url, max_size=None, open_timeout=10) as ws:
                    self._ws = ws
                    if not await self._auth(ws):
                        log.error("HA-Auth fehlgeschlagen (Token pruefen)")
                        self.last_error = "Home Assistant lehnt den Token ab"
                        self._ws = None
                        await ws.close()
                        await self._pause(30)
                        continue
                    await ws.send(json.dumps({"id": 1, "type": "subscribe_events",
                                              "event_type": "state_changed"}))
                    # Erst abonnieren, dann laden: so geht zwischendurch keine Aenderung verloren.
                    self._cache = {s["entity_id"]: s for s in await self._fetch_states()}
                    self.connected = True
                    self.last_error = None
                    log.info("HA WebSocket verbunden (%d Entitaeten)", len(self._cache))
                    async for raw in ws:
                        msg = json.loads(raw)
                        if msg.get("type") != "event":
                            continue
                        data = msg["event"]["data"]
                        new = data.get("new_state")
                        if new is None:
                            self._cache.pop(data.get("entity_id"), None)
                        elif new["entity_id"].split(".")[0] in SUPPORTED_DOMAINS:
                            self._cache[new["entity_id"]] = new
                            await on_state_changed(new)
            except asyncio.CancelledError:
                raise
            except Exception as e:  # noqa: BLE001
                log.warning("HA WebSocket getrennt: %s - Retry in 5s", e)
                self.last_error = f"Nicht erreichbar ({type(e).__name__})"
            self._ws = None
            self.connected = False
            await self._pause(5)


ha = HomeAssistant()
