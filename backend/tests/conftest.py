"""Test-Umgebung: echte App, aber Home Assistant und Sprach-Provider sind Attrappen."""
import os
import sys
from pathlib import Path

import pytest

os.environ["ADMIN_KEY"] = "test-admin"
os.environ["HA_TOKEN"] = "x"
os.environ["UPDATE_REPO"] = ""
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from fastapi.testclient import TestClient  # noqa: E402

from app import db, main  # noqa: E402
from app.config import settings  # noqa: E402
from app.ha import ha  # noqa: E402
from app.hub import hub  # noqa: E402
from app.voice import pipeline  # noqa: E402

ADMIN = {"x-admin-key": "test-admin"}


def state(entity_id: str, value: str = "off", **attrs) -> dict:
    return {"entity_id": entity_id, "state": value, "attributes": {"friendly_name": entity_id, **attrs}}


class FakeHA:
    """Ersetzt die HA-Aufrufe; merkt sich gesendete Befehle."""

    def __init__(self) -> None:
        self.states = [
            state("light.wohnzimmer", "on", brightness=128),
            state("light.kueche"),
            state("climate.wohnzimmer", "heat", temperature=21),
            state("binary_sensor.wohnzimmer_praesenz", device_class="occupancy"),
        ]
        self.commands: list[tuple] = []
        self.area_list = [
            {"area_id": "wohnzimmer", "name": "Wohnzimmer", "icon": None,
             "entity_ids": ["binary_sensor.wohnzimmer_praesenz", "climate.wohnzimmer", "light.wohnzimmer"]},
            {"area_id": "kueche", "name": "Küche", "icon": None, "entity_ids": ["light.kueche"]},
        ]

    async def get_states(self):
        return list(self.states)

    async def command(self, entity_id, action, value=None, extra=None):
        self.commands.append((entity_id, action, value, extra or {}))

    async def areas(self):
        return self.area_list


@pytest.fixture
def fake_ha(monkeypatch):
    f = FakeHA()
    monkeypatch.setattr(ha, "states", f.get_states)
    monkeypatch.setattr(ha, "command", f.command)
    monkeypatch.setattr(ha, "areas", f.areas)

    async def no_listen(_):
        return None

    monkeypatch.setattr(ha, "listen", no_listen)
    return f


@pytest.fixture
def client(tmp_path, monkeypatch, fake_ha):
    monkeypatch.setattr(settings, "db_path", str(tmp_path / "test.db"))
    monkeypatch.setattr(settings, "admin_key", "test-admin")
    db.close()
    hub.clients.clear()
    pipeline._history.clear()
    for fails in main._failures.values():
        fails.clear()
    with TestClient(main.app) as c:
        yield c
    db.close()


@pytest.fixture
def room(client):
    """Wohnzimmer mit Licht + Klima + Praesenzmelder, plus ein Tablet darin."""
    rid = client.post("/api/rooms", json={"name": "Wohnzimmer"}, headers=ADMIN).json()["id"]
    client.put(f"/api/rooms/{rid}/entities", headers=ADMIN,
               json={"entity_ids": ["light.wohnzimmer", "climate.wohnzimmer"]})
    t = client.post("/api/tablets", json={"name": "Wand", "room_id": rid}, headers=ADMIN).json()
    return {"id": rid, "tablet": t, "auth": {"Authorization": f"Bearer {t['token']}"}}
