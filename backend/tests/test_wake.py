"""Aktivierungswort: Zerlegung fuer den Erkenner, Einstellungen und Wahl des antwortenden Tablets."""
import asyncio

import pytest
from starlette.websockets import WebSocketDisconnect

from app import hub as hub_module
from app.hub import Hub
from app.voice import wakeword

from .conftest import ADMIN
from .test_core import FakeWS


# ---------- Zerlegung (Referenz: SentencePiece mit bpe.model des Modells) ----------
@pytest.mark.parametrize("text,expected", [
    ("Computer", "▁COMP U TER"),
    ("Alexa", "▁A LE X A"),
    ("Jarvis", "▁JA R VI S"),
    ("hey house guyst", "▁HE Y ▁HOUSE ▁GU Y S T"),
    ("Merry Christmas", "▁ME R RY ▁ CH R IST MA S"),
    ("Hello World", "▁HE LL O ▁WORLD"),
    ("Hausgeist", "▁HA US GE IST"),
    ("Größe", "▁G RO ES SE"),
])
def test_tokens_match_sentencepiece(text, expected):
    assert " ".join(wakeword.tokens(text)) == expected


def test_parse_words():
    assert wakeword.parse_words(" Computer ,, computer, Hey  Hausgeist (hey house guyst), 123") == [
        ("Computer", "COMPUTER"), ("Hey Hausgeist", "HEY HOUSE GUYST")]
    assert wakeword.parse_words("") == []
    assert len(wakeword.parse_words(",".join(f"wort{c}" for c in "abcdefgh"))) == wakeword.MAX_WORDS


def test_keyword_lines():
    assert wakeword.keywords("Computer, Hey Hausgeist (hey house guyst)", "hoch").splitlines() == [
        "▁COMP U TER #0.12 @Computer",
        "▁HE Y ▁HOUSE ▁GU Y S T #0.12 @Hey_Hausgeist"]
    assert "#0.2 " in wakeword.keywords("Alexa", "unbekannt")


# ---------- Einstellungen und /api/me ----------
def test_me_contains_wake_config(client, room):
    wake = client.get("/api/me", headers=room["auth"]).json()["wake"]
    assert wake == {"enabled": True, "words": ["Computer"], "keywords": "▁COMP U TER #0.2 @Computer"}

    client.put("/api/settings", headers=ADMIN, json={"wake_word": "Jarvis, Alexa", "wake_sensitivity": "niedrig"})
    wake = client.get("/api/me", headers=room["auth"]).json()["wake"]
    assert wake["words"] == ["Jarvis", "Alexa"]
    assert wake["keywords"].splitlines()[1] == "▁A LE X A #0.3 @Alexa"

    client.put(f"/api/tablets/{room['tablet']['id']}/display", headers=ADMIN, json={"voice_wake": False})
    assert client.get("/api/me", headers=room["auth"]).json()["wake"]["enabled"] is False

    client.put(f"/api/tablets/{room['tablet']['id']}/display", headers=ADMIN, json={})
    client.put("/api/settings", headers=ADMIN, json={"wake_word": ""})
    assert client.get("/api/me", headers=room["auth"]).json()["wake"]["enabled"] is False


def test_wake_settings_validated(client):
    r = client.put("/api/settings", headers=ADMIN, json={"wake_sensitivity": "extrem"})
    assert r.status_code == 422
    view = client.get("/api/settings", headers=ADMIN).json()
    assert view["wake_word"]["value"] == "Computer" and view["wake_sensitivity"]["value"] == "mittel"


def test_wake_word_change_reloads_tablets(client, room):
    with client.websocket_connect("/ws", headers=room["auth"]) as ws:
        client.put("/api/settings", headers=ADMIN, json={"wake_word": "Alexa"})
        with pytest.raises(WebSocketDisconnect) as e:
            ws.receive_json()
        assert e.value.code == 4000


def test_wake_preview(client):
    r = client.get("/api/wake/preview", headers=ADMIN, params={"word": "Computer, Hey Hausgeist (hey house guyst)"})
    words = r.json()["words"]
    assert [w["name"] for w in words] == ["Computer", "Hey Hausgeist"]
    assert words[1]["tokens"] == ["▁HE", "Y", "▁HOUSE", "▁GU", "Y", "S", "T"]
    assert "Computer" in r.json()["suggestions"]
    assert client.get("/api/wake/preview").status_code == 401


def test_websocket_single_tablet_accepted_at_once(client, room):
    with client.websocket_connect("/ws", headers=room["auth"]) as ws:
        ws.send_text("kein json")
        ws.send_json({"type": "wake_heard", "id": "r1", "level": -20})
        assert ws.receive_json() == {"type": "wake_result", "id": "r1", "accept": True}


# ---------- Wahl des antwortenden Tablets ----------
def _heard(h, ws, rid, level=-30.0, presence=False, near=False):
    return h.wake_heard(ws, {"type": "wake_heard", "id": rid, "level": level, "presence": presence, "near": near})


def _result(ws):
    return [m["accept"] for m in ws.sent if m["type"] == "wake_result"]


def _setup(h, n, rooms=None):
    socks = [FakeWS() for _ in range(n)]
    for i, ws in enumerate(socks):
        h.clients[ws] = hub_module.Client(f"t{i}", (rooms or [None] * n)[i], "both", True)
    return socks


def test_presence_beats_loudness():
    async def go():
        h = Hub(window=0.05)
        loud, seen, quiet = _setup(h, 3)
        await _heard(h, loud, "a", level=-10)
        await _heard(h, seen, "b", level=-35, presence=True)
        await _heard(h, quiet, "c", level=-50)  # alle haben gemeldet -> sofort entschieden
        return loud, seen, quiet
    loud, seen, quiet = asyncio.run(go())
    assert (_result(loud), _result(seen), _result(quiet)) == ([False], [True], [False])


def test_loudest_wins_and_late_is_rejected():
    async def go():
        h = Hub(window=0.05)
        a, b, c = _setup(h, 3)
        await _heard(h, a, "a", level=-40)
        await _heard(h, b, "b", level=-18)
        assert _result(a) == _result(b) == []  # wartet noch auf das dritte Tablet
        await asyncio.sleep(0.1)
        await _heard(h, c, "c", level=-5)      # kommt nach der Entscheidung
        return a, b, c
    a, b, c = asyncio.run(go())
    assert (_result(a), _result(b), _result(c)) == ([False], [True], [False])


def test_room_presence_sensor_counts():
    async def go():
        h = Hub(window=0.05)
        h.occupied = lambda room_id: room_id == "kueche"
        wohnzimmer, kueche = _setup(h, 2, rooms=["wohnzimmer", "kueche"])
        await _heard(h, wohnzimmer, "a", level=-10)
        await _heard(h, kueche, "b", level=-30)
        return wohnzimmer, kueche
    wohnzimmer, kueche = asyncio.run(go())
    assert (_result(wohnzimmer), _result(kueche)) == ([False], [True])


def test_new_call_after_pause(monkeypatch):
    async def go():
        h = Hub(window=0.05)
        a, b = _setup(h, 2)
        await _heard(h, a, "a1", level=-10)
        await asyncio.sleep(0.1)  # b hat nichts gehoert -> a nach Ablauf des Fensters
        monkeypatch.setattr(hub_module, "WAKE_LATE", 0)
        await _heard(h, b, "b2", level=-10)
        await asyncio.sleep(0.1)
        return a, b
    a, b = asyncio.run(go())
    assert (_result(a), _result(b)) == ([True], [True])


def test_tablets_without_wake_word_are_not_waited_for():
    async def go():
        h = Hub(window=5)
        a, b = _setup(h, 2)
        h.clients[b].voice_wake = False
        await _heard(h, a, "a")
        return a
    assert _result(asyncio.run(go())) == [True]
