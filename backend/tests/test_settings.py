"""Ersteinrichtung, Anmeldung, Einstellungen aus der Verwaltung und Sicherung."""
import pytest

from app import config, main
from app.config import settings
from app.ha import ha
from app.voice import pipeline

from .conftest import ADMIN


@pytest.fixture
def fresh(client, monkeypatch):
    """Server ohne ADMIN_KEY, also noch nicht eingerichtet."""
    monkeypatch.setattr(settings, "admin_key", "")
    return client


def _bearer(token: str) -> dict:
    return {"x-admin-key": token}


# ---------- Ersteinrichtung und Anmeldung ----------
def test_setup_once_then_login(fresh):
    assert fresh.get("/api/setup").json()["needs_setup"] is True
    assert fresh.get("/api/rooms").status_code == 503
    assert fresh.post("/api/setup", json={"password": "kurz"}).status_code == 422

    token = fresh.post("/api/setup", json={"password": "geheim123"}).json()["token"]
    assert fresh.get("/api/rooms", headers=_bearer(token)).status_code == 200
    assert fresh.get("/api/setup").json()["needs_setup"] is False
    # Ein zweites Mal einrichten geht nicht, sonst koennte jeder das Passwort ueberschreiben.
    assert fresh.post("/api/setup", json={"password": "anderes123"}).status_code == 409

    assert fresh.post("/api/admin/login", json={"password": "falsch"}).status_code == 401
    token2 = fresh.post("/api/admin/login", json={"password": "geheim123"}).json()["token"]
    assert token2 != token
    fresh.post("/api/admin/logout", headers=_bearer(token2))
    assert fresh.get("/api/rooms", headers=_bearer(token2)).status_code == 401
    assert fresh.get("/api/rooms", headers=_bearer(token)).status_code == 200


def test_login_rate_limit(fresh):
    fresh.post("/api/setup", json={"password": "geheim123"})
    for _ in range(10):
        assert fresh.post("/api/admin/login", json={"password": "nein"}).status_code == 401
    assert fresh.post("/api/admin/login", json={"password": "geheim123"}).status_code == 429


def test_password_change_ends_other_sessions(fresh):
    a = fresh.post("/api/setup", json={"password": "geheim123"}).json()["token"]
    b = fresh.post("/api/admin/login", json={"password": "geheim123"}).json()["token"]
    r = fresh.put("/api/admin/password", headers=_bearer(a), json={"current": "falsch", "new": "neues-pw-1"})
    assert r.status_code == 403
    assert fresh.put("/api/admin/password", headers=_bearer(a),
                     json={"current": "geheim123", "new": "neues-pw-1"}).status_code == 200
    assert fresh.get("/api/rooms", headers=_bearer(a)).status_code == 200
    assert fresh.get("/api/rooms", headers=_bearer(b)).status_code == 401
    assert fresh.post("/api/admin/login", json={"password": "neues-pw-1"}).status_code == 200


def test_env_admin_key_still_works_as_fallback(client):
    # ADMIN_KEY (conftest) gilt auch nach dem Festlegen eines Passworts, z. B. wenn es vergessen wurde.
    assert client.post("/api/admin/login", json={"password": "test-admin"}).status_code == 200
    assert client.post("/api/setup", json={"password": "geheim123"}).status_code == 409


# ---------- Einstellungen ----------
def test_settings_hide_secrets_and_override_env(client, monkeypatch):
    s = client.get("/api/settings", headers=ADMIN).json()
    assert s["ha_token"] == {"value": None, "secret": True, "set": True, "source": "env", "default": None}
    assert s["llm_provider"]["value"] == "openai"

    reconnects = []

    async def fake_reconfigure():
        reconnects.append(1)

    monkeypatch.setattr(ha, "reconfigure", fake_reconfigure)
    s = client.put("/api/settings", headers=ADMIN,
                   json={"openai_api_key": " sk-test ", "llm_provider": "xai", "ha_url": "http://10.0.0.2:8123"}).json()
    assert settings.openai_api_key == "sk-test"
    assert settings.llm_provider == "xai"
    assert s["openai_api_key"]["value"] is None and s["openai_api_key"]["source"] == "admin"
    assert s["ha_url"]["value"] == "http://10.0.0.2:8123"
    assert reconnects == [1]
    assert "sk-test" not in client.get("/api/settings", headers=ADMIN).text

    # null = Wert aus der Verwaltung loeschen, dann gilt wieder der Container
    client.put("/api/settings", headers=ADMIN, json={"llm_provider": None})
    assert settings.llm_provider == config.env_settings.llm_provider


@pytest.mark.parametrize("body", [{"llm_provider": "foo"}, {"ha_url": "homeassistant"},
                                  {"update_repo": "kein repo"}, {"unbekannt": "x"}, {"stt_language": "deutsch"}])
def test_settings_validated(client, body):
    assert client.put("/api/settings", headers=ADMIN, json=body).status_code == 422


def test_settings_survive_restart(client):
    client.put("/api/settings", headers=ADMIN, json={"elevenlabs_voice_id": "v1", "assistant_instructions": "Duze mich."})
    config.apply({})  # wie ein Neustart ohne Datenbank
    assert settings.elevenlabs_voice_id == ""
    config.apply(main.db.get_settings())
    assert settings.elevenlabs_voice_id == "v1"
    assert settings.assistant_instructions == "Duze mich."


def test_settings_test_uses_unsaved_values(client, monkeypatch):
    seen = {}

    async def probe(url, token):
        seen.update(url=url, token=token)
        return {"ok": True, "message": "ok"}

    monkeypatch.setattr(ha, "probe", probe)
    r = client.post("/api/settings/test/ha", headers=ADMIN, json={"ha_url": "http://neu:8123", "ha_token": ""})
    assert r.json()["ok"] is True
    assert seen == {"url": "http://neu:8123", "token": "x"}  # leerer Token = gespeicherter Wert
    assert settings.ha_url != "http://neu:8123"  # nichts gespeichert

    r = client.post("/api/settings/test/llm", headers=ADMIN, json={"llm_provider": "custom"}).json()
    assert r["ok"] is False and "fehlt" in r["message"]


def test_voice_test_runs_pipeline_for_room(client, room, monkeypatch):
    calls = []

    async def fake_run(text, room_id, session):
        calls.append((text, room_id, session))
        return {"reply": "Erledigt.", "actions": []}

    monkeypatch.setattr(pipeline, "run", fake_run)
    monkeypatch.setattr(settings, "elevenlabs_api_key", "")
    r = client.post("/api/voice/test", headers=ADMIN, json={"text": "Licht an", "room_id": room["id"]})
    assert r.json() == {"reply": "Erledigt.", "actions": []}  # ohne Stimme, weil TTS nicht eingerichtet
    assert calls == [("Licht an", room["id"], f"admin:{room['id']}")]
    assert client.post("/api/voice/test", headers=ADMIN, json={"text": "x", "room_id": "nope"}).status_code == 404


# ---------- Sicherung ----------
def test_backup_roundtrip(client, room):
    client.put("/api/settings", headers=ADMIN, json={"openai_api_key": "sk-1", "assistant_instructions": "kurz"})
    r = client.get("/api/backup", headers=ADMIN)
    assert "attachment" in r.headers["content-disposition"]
    backup = r.json()
    assert backup["settings"]["openai_api_key"] == "sk-1"
    assert "_admin_password" not in backup["settings"]
    assert len(backup["tablets"]) == 1 and backup["tablets"][0]["token"] == room["tablet"]["token"]

    client.delete(f"/api/rooms/{room['id']}", headers=ADMIN)
    client.put("/api/settings", headers=ADMIN, json={"openai_api_key": "sk-2", "xai_api_key": "x-weg"})
    assert client.post("/api/backup", headers=ADMIN, json=backup).json() == {"rooms": 1, "tablets": 1}

    rooms = client.get("/api/rooms", headers=ADMIN).json()
    assert [r["name"] for r in rooms] == ["Wohnzimmer"]
    assert sorted(rooms[0]["entity_ids"]) == ["climate.wohnzimmer", "light.wohnzimmer"]
    assert settings.openai_api_key == "sk-1"
    assert settings.xai_api_key == ""
    assert client.get("/api/me", headers=room["auth"]).json()["room"]["name"] == "Wohnzimmer"


def test_backup_rejects_garbage(client, room):
    assert client.post("/api/backup", headers=ADMIN, json={"format": "etwas"}).status_code == 422
    bad = {"format": "hausgeist-backup", "rooms": [{"name": "ohne id"}]}
    assert client.post("/api/backup", headers=ADMIN, json=bad).status_code == 422
    assert len(client.get("/api/rooms", headers=ADMIN).json()) == 1  # nichts kaputt gemacht


def test_parallel_requests(fresh):
    # Die Verwaltung laedt mehrere Dinge gleichzeitig; frueher teilten sich alle Threads eine
    # sqlite-Verbindung, was sporadisch mit "bad parameter or other API misuse" scheiterte.
    from concurrent.futures import ThreadPoolExecutor

    token = fresh.post("/api/setup", json={"password": "geheim123"}).json()["token"]
    paths = ["/api/status", "/api/settings", "/api/rooms", "/api/tablets"] * 25
    with ThreadPoolExecutor(8) as pool:
        codes = list(pool.map(lambda p: fresh.get(p, headers=_bearer(token)).status_code, paths))
    assert set(codes) == {200}


def test_admin_files_revalidated(client):
    # Nach einem Update soll der Browser die neue Verwaltung laden und nicht die alte aus dem Cache.
    r = client.get("/admin/admin.js")
    assert r.headers["cache-control"] == "no-cache"
    assert client.get("/admin/admin.js", headers={"if-none-match": r.headers["etag"]}).status_code == 304
