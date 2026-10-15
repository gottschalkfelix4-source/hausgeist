"""Bausteine ohne HTTP: Service-Abbildung, Live-Verteilung, Sprachablauf, Update-Info."""
import asyncio
import json
from types import SimpleNamespace

import pytest

from app import db, updates
from app.ha import _service_data
from app.hub import Hub
from app.voice import pipeline


# ---------- HA-Service-Daten ----------
@pytest.mark.parametrize("domain,action,value,extra,expected", [
    ("light", "on", 40, None, {"brightness_pct": 40}),
    ("light", "on", None, {"color_temp_kelvin": 2700, "evil": 1}, {"color_temp_kelvin": 2700}),
    ("light", "on", 60, {"hs_color": [30, 80]}, {"hs_color": [30, 80], "brightness_pct": 60}),
    ("switch", "on", None, {"hs_color": [1, 2]}, {}),  # Farbe nur bei Licht
    ("climate", "set_temperature", "21.5", None, {"temperature": 21.5}),
    ("climate", "set_mode", "heat", None, {"hvac_mode": "heat"}),
    ("cover", "set_position", 30.0, None, {"position": 30}),
    ("media_player", "set_volume", 0.4, None, {"volume_level": 0.4}),
])
def test_service_data(domain, action, value, extra, expected):
    assert _service_data(domain, action, value, extra) == expected


# ---------- Hub ----------
class FakeWS:
    def __init__(self):
        self.sent: list[dict] = []

    async def accept(self):
        pass

    async def send_json(self, msg):
        self.sent.append(msg)


def test_hub_filters_by_room_and_wakes(client, room):
    rid = room["id"]
    db.conn().execute("UPDATE rooms SET presence_entity='binary_sensor.wohnzimmer_praesenz' WHERE id=?", (rid,))
    h = Hub()
    here, here_cam, elsewhere = FakeWS(), FakeWS(), FakeWS()

    async def go():
        await h.add(here, "t1", rid, "both")
        await h.add(here_cam, "t2", rid, "camera")
        await h.add(elsewhere, "t3", "anderer", "both")
        await h.on_state_changed({"entity_id": "light.wohnzimmer", "state": "on"})
        await h.on_state_changed({"entity_id": "binary_sensor.wohnzimmer_praesenz", "state": "on"})

    asyncio.run(go())
    assert [m["type"] for m in here.sent] == ["state", "wake"]
    assert [m["type"] for m in here_cam.sent] == ["state"]  # nur Kamera: kein Wecken durch den Melder
    assert elsewhere.sent == []
    assert h.online() == {"t1", "t2", "t3"}


# ---------- Sprachablauf ----------
def _tool_call(entity_id, action, **kw):
    return SimpleNamespace(id=f"c-{entity_id}", function=SimpleNamespace(
        arguments=json.dumps({"entity_id": entity_id, "action": action, **kw})))


class FakeLLM:
    """Antwortet nacheinander mit den vorgegebenen Nachrichten und merkt sich die Anfragen."""

    def __init__(self, *replies):
        self.replies = list(replies)
        self.calls: list[list] = []
        self.chat = SimpleNamespace(completions=SimpleNamespace(create=self._create))

    async def _create(self, model, messages, tools):
        self.calls.append(list(messages))
        msg = self.replies.pop(0)
        return SimpleNamespace(choices=[SimpleNamespace(message=msg)])


def _msg(content=None, tool_calls=None):
    return SimpleNamespace(content=content, tool_calls=tool_calls)


def test_pipeline_controls_only_room_devices(client, room, fake_ha, monkeypatch):
    llm = FakeLLM(
        _msg(tool_calls=[_tool_call("light.wohnzimmer", "on", value=30, color_temp_kelvin=2700),
                         _tool_call("light.kueche", "on")]),
        _msg("Licht ist gedimmt."),
    )
    monkeypatch.setattr(pipeline, "llm_client", lambda: (llm, "m"))
    r = asyncio.run(pipeline.run("Mach es gemütlich", room["id"], "t1"))
    assert r["reply"] == "Licht ist gedimmt."
    assert fake_ha.commands == [("light.wohnzimmer", "on", 30, {"color_temp_kelvin": 2700})]
    tool_results = [m["content"] for m in llm.calls[1] if isinstance(m, dict) and m.get("role") == "tool"]
    assert tool_results == ["ok", "Fehler: Geraet gehoert nicht zu diesem Raum."]
    assert "light.wohnzimmer" in llm.calls[0][0]["content"]  # Raumkontext im Systemprompt
    assert "light.kueche" not in llm.calls[0][0]["content"]


def test_pipeline_remembers_short_conversation(client, room, monkeypatch):
    llm = FakeLLM(_msg("Erledigt."), _msg("Heller gemacht."), _msg("Hallo."))
    monkeypatch.setattr(pipeline, "llm_client", lambda: (llm, "m"))
    asyncio.run(pipeline.run("Licht an", room["id"], "t1"))
    asyncio.run(pipeline.run("und heller", room["id"], "t1"))
    roles = [m["role"] for m in llm.calls[1]]
    assert roles == ["system", "user", "assistant", "user"]

    # Anderes Tablet teilt das Gedaechtnis nicht; abgelaufenes wird vergessen
    asyncio.run(pipeline.run("Hallo", room["id"], "t2"))
    assert [m["role"] for m in llm.calls[2]] == ["system", "user"]
    ts, msgs = pipeline._history["t1"]
    pipeline._history["t1"] = (ts - pipeline.HISTORY_TTL - 1, msgs)
    assert pipeline.recall("t1") == []


# ---------- Update-Info ----------
def test_update_parse_picks_apk():
    rel = {"tag_name": "v0.2.0", "html_url": "https://x/r", "body": "Neu",
           "assets": [{"name": "src.zip", "browser_download_url": "z"},
                      {"name": "hausgeist-0.2.0.apk", "browser_download_url": "https://x/a.apk"}]}
    assert updates._parse(rel) == {"version": "0.2.0", "apk_url": "https://x/a.apk",
                                   "page_url": "https://x/r", "notes": "Neu"}
    assert updates._parse({"tag_name": "v1", "assets": []}) is None


# ---------- HA-Bereiche ----------
def test_ha_areas_resolve_device_area(monkeypatch):
    from app.ha import HomeAssistant
    h = HomeAssistant()

    async def ws_call(*types):
        assert types == ("config/area_registry/list", "config/entity_registry/list", "config/device_registry/list")
        return [
            [{"area_id": "wz", "name": "Wohnzimmer"}, {"area_id": "bad", "name": "Bad"}],
            [{"entity_id": "light.decke", "area_id": None, "device_id": "d1"},          # Bereich vom Geraet
             {"entity_id": "light.stehlampe", "area_id": "wz", "device_id": "d2"},     # eigener Bereich gewinnt
             {"entity_id": "sensor.versteckt", "area_id": "wz", "hidden_by": "user"},
             {"entity_id": "automation.x", "area_id": "wz"},                            # nicht unterstuetzt
             {"entity_id": "switch.bad", "area_id": "bad", "disabled_by": "user"}],
            [{"id": "d1", "area_id": "wz"}, {"id": "d2", "area_id": "bad"}],
        ]

    monkeypatch.setattr(h, "ws_call", ws_call)
    areas = asyncio.run(h.areas())
    assert areas == [
        {"area_id": "wz", "name": "Wohnzimmer", "icon": None, "entity_ids": ["light.decke", "light.stehlampe"]},
        {"area_id": "bad", "name": "Bad", "icon": None, "entity_ids": []},
    ]
