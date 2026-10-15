"""Sprachassistent: Text + Raumkontext -> LLM mit Tool-Calling -> HA-Aktionen + Antworttext."""
import json

from .. import db
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
                "value": {"type": "number",
                          "description": "Helligkeit 0-100, Temperatur in C, Position 0-100, Lautstaerke 0-1"},
            },
            "required": ["entity_id", "action"],
        },
    },
}]


async def _room_context(room_id: str | None) -> tuple[str, set[str]]:
    if not room_id:
        return "Kein Raum zugewiesen.", set()
    ids = set(db.room_entity_ids(room_id))
    lines = []
    for s in await ha.states():
        if s["entity_id"] in ids:
            name = s["attributes"].get("friendly_name", s["entity_id"])
            lines.append(f"- {s['entity_id']} ({name}): {s['state']}")
    return "\n".join(lines) or "Keine Geraete im Raum.", ids


async def run(text: str, room_id: str | None) -> dict:
    context, allowed = await _room_context(room_id)
    room = db.conn().execute("SELECT name FROM rooms WHERE id=?", (room_id,)).fetchone()
    system = (
        "Du bist der Sprachassistent eines Smart Homes. Antworte kurz und natuerlich auf Deutsch, "
        "in ein bis zwei Saetzen, ohne Markdown. Steuere Geraete ausschliesslich ueber das Tool "
        f"und nur diese, die zum Raum '{room['name'] if room else '-'}' gehoeren:\n{context}"
    )
    client, model = llm_client()
    messages = [{"role": "system", "content": system}, {"role": "user", "content": text}]
    actions: list[dict] = []

    for _ in range(4):
        res = await client.chat.completions.create(model=model, messages=messages, tools=TOOLS)
        msg = res.choices[0].message
        if not msg.tool_calls:
            return {"reply": msg.content or "", "actions": actions}
        messages.append(msg)
        for call in msg.tool_calls:
            args = json.loads(call.function.arguments)
            if args.get("entity_id") not in allowed:
                result = "Fehler: Geraet gehoert nicht zu diesem Raum."
            else:
                try:
                    await ha.command(args["entity_id"], args["action"], args.get("value"))
                    actions.append(args)
                    result = "ok"
                except Exception as e:  # noqa: BLE001
                    result = f"Fehler: {e}"
            messages.append({"role": "tool", "tool_call_id": call.id, "content": result})
    return {"reply": "Das hat leider nicht geklappt.", "actions": actions}
