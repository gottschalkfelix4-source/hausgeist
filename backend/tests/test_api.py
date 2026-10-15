import pytest
from starlette.websockets import WebSocketDisconnect

from app.config import settings

from .conftest import ADMIN


# ---------- Admin-Zugang ----------
def test_admin_requires_key(client):
    assert client.get("/api/rooms").status_code == 401
    assert client.get("/api/rooms", headers={"x-admin-key": "falsch"}).status_code == 401
    assert client.get("/api/rooms", headers=ADMIN).status_code == 200


@pytest.mark.parametrize("value", ["", "change-me"])
def test_default_admin_key_is_locked(client, monkeypatch, value):
    monkeypatch.setattr(settings, "admin_key", value)
    assert client.get("/api/rooms", headers={"x-admin-key": value}).status_code == 503


def test_status(client, room):
    s = client.get("/api/status", headers=ADMIN).json()
    assert s["ha"]["token_set"] is True
    assert s["tablets_online"] == 0
    assert {"stt", "llm", "tts"} <= s["voice"].keys()


# ---------- Raeume ----------
def test_room_crud(client, room):
    rid = room["id"]
    assert client.patch(f"/api/rooms/{rid}", json={"name": "Wohnen"}, headers=ADMIN).status_code == 200
    rooms = client.get("/api/rooms", headers=ADMIN).json()
    assert rooms[0]["name"] == "Wohnen"
    assert sorted(rooms[0]["entity_ids"]) == ["climate.wohnzimmer", "light.wohnzimmer"]
    assert client.patch("/api/rooms/gibtsnicht", json={"name": "x"}, headers=ADMIN).status_code == 404

    client.delete(f"/api/rooms/{rid}", headers=ADMIN)
    assert client.get("/api/rooms", headers=ADMIN).json() == []
    # Tablet bleibt, hat aber keinen Raum mehr
    assert client.get("/api/tablets", headers=ADMIN).json()[0]["room_id"] is None


def test_import_areas_creates_and_links(client, fake_ha):
    # Gleichnamiger Raum ohne Verknuepfung wird uebernommen statt doppelt angelegt
    client.post("/api/rooms", json={"name": "küche"}, headers=ADMIN)
    r = client.post("/api/rooms/import-areas", json={}, headers=ADMIN).json()
    assert r == {"created": ["Wohnzimmer"], "updated": ["Küche"]}
    rooms = {x["name"]: x for x in client.get("/api/rooms", headers=ADMIN).json()}
    assert rooms["Wohnzimmer"]["ha_area_id"] == "wohnzimmer"
    assert rooms["Wohnzimmer"]["presence_entity"] == "binary_sensor.wohnzimmer_praesenz"  # automatisch
    assert rooms["küche"]["presence_entity"] is None
    assert rooms["küche"]["entity_ids"] == ["light.kueche"]

    areas = client.get("/api/ha/areas", headers=ADMIN).json()
    assert all(a["room_id"] for a in areas)

    # Zweiter Import ergaenzt nur, mit replace wird ersetzt
    fake_ha.area_list[0]["entity_ids"] = ["light.wohnzimmer"]
    client.post("/api/rooms/import-areas", json={"area_ids": ["wohnzimmer"]}, headers=ADMIN)
    wz = next(x for x in client.get("/api/rooms", headers=ADMIN).json() if x["name"] == "Wohnzimmer")
    assert len(wz["entity_ids"]) == 3
    client.post("/api/rooms/import-areas", json={"area_ids": ["wohnzimmer"], "replace_entities": True}, headers=ADMIN)
    wz = next(x for x in client.get("/api/rooms", headers=ADMIN).json() if x["name"] == "Wohnzimmer")
    assert wz["entity_ids"] == ["light.wohnzimmer"]


# ---------- Tablets ----------
def test_tablet_sees_only_its_room(client, room):
    me = client.get("/api/me", headers=room["auth"]).json()
    assert me["room"]["name"] == "Wohnzimmer"
    assert {e["entity_id"] for e in me["entities"]} == {"light.wohnzimmer", "climate.wohnzimmer"}
    assert me["display"]["dim_after"] == 30
    assert client.get("/api/me", headers={"Authorization": "Bearer falsch"}).status_code == 401


def test_tablet_list_hides_token(client, room):
    t = client.get("/api/tablets", headers=ADMIN).json()[0]
    assert t["token"] is None
    assert t["pair_code"] == room["tablet"]["pair_code"]
    assert t["online"] is False


def test_tablet_patch_and_unknown_room(client, room):
    tid = room["tablet"]["id"]
    assert client.patch(f"/api/tablets/{tid}", json={"room_id": "nope"}, headers=ADMIN).status_code == 404
    client.patch(f"/api/tablets/{tid}", json={"name": "Flur"}, headers=ADMIN)
    t = client.get("/api/tablets", headers=ADMIN).json()[0]
    assert (t["name"], t["room_id"]) == ("Flur", room["id"])  # room_id nicht mitgeschickt -> bleibt
    client.patch(f"/api/tablets/{tid}", json={"room_id": None}, headers=ADMIN)
    assert client.get("/api/tablets", headers=ADMIN).json()[0]["room_id"] is None


def test_display_settings_validated(client, room):
    tid = room["tablet"]["id"]
    assert client.put(f"/api/tablets/{tid}/display", json={"dim_after": 1}, headers=ADMIN).status_code == 422
    client.put(f"/api/tablets/{tid}/display", json={"dim_after": 45, "wake_mode": "sensor"}, headers=ADMIN)
    d = client.get("/api/me", headers=room["auth"]).json()["display"]
    assert (d["dim_after"], d["wake_mode"], d["sleep_after"]) == (45, "sensor", 120)


def test_rotate_token_and_delete(client, room):
    tid = room["tablet"]["id"]
    new = client.post(f"/api/tablets/{tid}/token", headers=ADMIN).json()
    assert client.get("/api/me", headers=room["auth"]).status_code == 401
    assert client.get("/api/me", headers={"Authorization": f"Bearer {new['token']}"}).status_code == 200
    client.delete(f"/api/tablets/{tid}", headers=ADMIN)
    assert client.get("/api/me", headers={"Authorization": f"Bearer {new['token']}"}).status_code == 401


# ---------- Kopplung ----------
def test_pairing_code_is_single_use(client, room):
    code = room["tablet"]["pair_code"]
    r = client.post("/api/pair", json={"code": f"{code[:3]} {code[3:]}"})  # Leerzeichen erlaubt
    assert r.status_code == 200
    assert r.json() == {"token": room["tablet"]["token"], "tablet": "Wand"}
    assert client.post("/api/pair", json={"code": code}).status_code == 404


def test_pairing_code_expires(client, room, monkeypatch):
    import time
    real = time.time
    monkeypatch.setattr(time, "time", lambda: real() + 16 * 60)
    assert client.post("/api/pair", json={"code": room["tablet"]["pair_code"]}).status_code == 404


def test_pairing_rate_limit(client, room):
    code = room["tablet"]["pair_code"]
    wrong = "000000" if code != "000000" else "111111"
    for _ in range(10):
        assert client.post("/api/pair", json={"code": wrong}).status_code == 404
    assert client.post("/api/pair", json={"code": code}).status_code == 429


# ---------- Steuerung ----------
def test_command_limited_to_room(client, room, fake_ha):
    ok = client.post("/api/entities/light.wohnzimmer/command", headers=room["auth"],
                     json={"action": "on", "value": 40, "data": {"hs_color": [30, 80]}})
    assert ok.status_code == 200
    assert fake_ha.commands == [("light.wohnzimmer", "on", 40, {"hs_color": [30, 80]})]
    other = client.post("/api/entities/light.kueche/command", headers=room["auth"], json={"action": "on"})
    assert other.status_code == 403


# ---------- Live-Kanal ----------
def test_websocket_auth(client, room):
    with client.websocket_connect("/ws", headers=room["auth"]):
        assert client.get("/api/status", headers=ADMIN).json()["tablets_online"] == 1
    with client.websocket_connect(f"/ws?token={room['tablet']['token']}"):  # App 0.1.x
        pass
    with pytest.raises(WebSocketDisconnect) as e, client.websocket_connect("/ws", headers={"Authorization": "Bearer x"}) as ws:
        ws.receive_json()
    assert e.value.code == 4401


def test_websocket_reload_on_settings_change(client, room):
    with client.websocket_connect("/ws", headers=room["auth"]) as ws:
        client.put(f"/api/tablets/{room['tablet']['id']}/display", json={}, headers=ADMIN)
        with pytest.raises(WebSocketDisconnect) as e:
            ws.receive_json()
        assert e.value.code == 4000


def test_static_admin(client):
    r = client.get("/", follow_redirects=False)
    assert r.headers["location"] == "/admin/"
    assert "Hausgeist" in client.get("/admin/").text
    assert client.get("/health").json()["ok"] is True
