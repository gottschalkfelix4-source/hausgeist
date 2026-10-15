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
        self.http = httpx.AsyncClient(
            base_url=settings.ha_url.rstrip("/"),
            headers={"Authorization": f"Bearer {settings.ha_token}"},
            timeout=10,
        )

    async def states(self) -> list[dict]:
        r = await self.http.get("/api/states")
        r.raise_for_status()
        return [s for s in r.json() if s["entity_id"].split(".")[0] in SUPPORTED_DOMAINS]

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

    async def listen(self, on_state_changed: Callable[[dict], Awaitable[None]]) -> None:
        """Dauerhaft state_changed-Events empfangen, mit Reconnect."""
        ws_url = settings.ha_url.rstrip("/").replace("http", "ws", 1) + "/api/websocket"
        while True:
            try:
                async with websockets.connect(ws_url, max_size=None) as ws:
                    await ws.recv()  # auth_required
                    await ws.send(json.dumps({"type": "auth", "access_token": settings.ha_token}))
                    if json.loads(await ws.recv()).get("type") != "auth_ok":
                        log.error("HA-Auth fehlgeschlagen (HA_TOKEN pruefen)")
                        await asyncio.sleep(30)
                        continue
                    await ws.send(json.dumps({"id": 1, "type": "subscribe_events",
                                              "event_type": "state_changed"}))
                    log.info("HA WebSocket verbunden")
                    async for raw in ws:
                        msg = json.loads(raw)
                        if msg.get("type") == "event":
                            new = msg["event"]["data"].get("new_state")
                            if new and new["entity_id"].split(".")[0] in SUPPORTED_DOMAINS:
                                await on_state_changed(new)
            except Exception as e:  # noqa: BLE001
                log.warning("HA WebSocket getrennt: %s - Retry in 5s", e)
                await asyncio.sleep(5)


ha = HomeAssistant()
