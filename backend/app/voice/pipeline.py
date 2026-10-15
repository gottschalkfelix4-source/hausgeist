"""Sprachassistent: Text + Raumkontext -> LLM mit Tool-Calling -> HA-Aktionen + Antworttext."""
import json
import time

from .. import db
from ..config import settings
from ..ha import ACTION_SERVICES, ha
from .providers import llm_client

TOOLS = [{
    "type": "function",
    "function": {
        "name": "control_device",
        "description": "Steuert ein Geraet im aktuellen Raum.",
        "parameters": {
            "type": "object",
            "properties": {
                "entity_id": {"type": "string"},
                "action": {"type": "string",
                           "enum": sorted({a for _, a in ACTION_SERVICES})},
                "value": {"type": ["number", "string"],
                          "description": "Helligkeit 0-100, Temperatur in C, Position 0-100, Lautstaerke 0-1, "
                                         "bei set_mode/set_fan_mode/set_preset der Modus als Text (z. B. heat, cool, eco)"},
                "color_temp_kelvin": {"type": "integer",
                                      "description": "Nur Licht: Weisston, 2200 (warm) bis 6500 (kalt)"},
                "hs_color": {"type": "array", "items": {"type": "number"}, "minItems": 2, "maxItems": 2,
                             "description": "Nur Licht: Farbe als [Farbton 0-360, Saettigung 0-100]"},
            },
            "required": ["entity_id", "action"],
        },
    },
}]

# Kurzes Gedaechtnis pro Tablet, damit Rueckfragen wie "und jetzt etwas heller" funktionieren.
HISTORY_TTL = 120  # s seit der letzten Anfrage
HISTORY_MAX = 6    # Nachrichten (Nutzer + Assistent)
_history: dict[str, tuple[float, list[dict]]] = {}


def _recall(key: str | None) -> list[dict]:
    if not key or key not in _history:
        return []
    ts, msgs = _history[key]
    if time.monotonic() - ts > HISTORY_TTL:
        _history.pop(key, None)
        return []
    return msgs


def _remember(key: str | None, text: str, reply: str) -> None:
    if not key:
        return
    msgs = _recall(key) + [{"role": "user", "content": text}, {"role": "assistant", "content": reply}]
    _history[key] = (time.monotonic(), msgs[-HISTORY_MAX:])


def forget(key: str) -> None:
    _history.pop(key, None)


async def _room_context(room_id: str | None) -> tuple[str, set[str]]:
    if not room_id:
        return "Kein Raum zugewiesen.", set()
    ids = set(db.room_entity_ids(room_id))
    lines = []
    for s in await ha.states():
        if s["entity_id"] in ids:
            a = s["attributes"]
            name = a.get("friendly_name", s["entity_id"])
            extra = [f"{k}={a[k]}" for k in ("brightness", "current_temperature", "temperature",
                                               "hvac_modes", "current_position") if a.get(k) is not None]
            lines.append(f"- {s['entity_id']} ({name}): {s['state']}" + (f" [{', '.join(map(str, extra))}]" if extra else ""))
    return "\n".join(lines) or "Keine Geraete im Raum.", ids


async def run(text: str, room_id: str | None, session: str | None = None) -> dict:
    context, allowed = await _room_context(room_id)
    room = db.conn().execute("SELECT name FROM rooms WHERE id=?", (room_id,)).fetchone()
    system = (
        "Du bist Hausgeist, der Sprachassistent eines Smart Homes. Antworte kurz und natuerlich auf Deutsch, "
        "in ein bis zwei Saetzen, ohne Markdown. Steuere Geraete ausschliesslich ueber das Tool "
        f"und nur diese, die zum Raum '{room['name'] if room else '-'}' gehoeren:\n{context}"
    )
    if settings.assistant_instructions.strip():
        system += "\n\nZusaetzliche Anweisungen des Hausherrn:\n" + settings.assistant_instructions.strip()
    client, model = llm_client()
    messages = [{"role": "system", "content": system}, *_recall(session), {"role": "user", "content": text}]
    actions: list[dict] = []

    for _ in range(4):
        res = await client.chat.completions.create(model=model, messages=messages, tools=TOOLS)
        msg = res.choices[0].message
        if not msg.tool_calls:
            reply = msg.content or ""
            _remember(session, text, reply)
            return {"reply": reply, "actions": actions}
        messages.append(msg)
        for call in msg.tool_calls:
            args = json.loads(call.function.arguments)
            if args.get("entity_id") not in allowed:
                result = "Fehler: Geraet gehoert nicht zu diesem Raum."
            else:
                try:
                    extra = {k: args[k] for k in ("color_temp_kelvin", "hs_color") if args.get(k) is not None}
                    await ha.command(args["entity_id"], args["action"], args.get("value"), extra)
                    actions.append(args)
                    result = "ok"
                except Exception as e:  # noqa: BLE001
                    result = f"Fehler: {e}"
            messages.append({"role": "tool", "tool_call_id": call.id, "content": result})
    return {"reply": "Das hat leider nicht geklappt.", "actions": actions}
