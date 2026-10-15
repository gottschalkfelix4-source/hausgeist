"""Live-Sprachmodelle gegen nachgebaute Server (Ablauf laut Doku von OpenAI GPT-Live und xAI Grok Voice)."""
import asyncio
import base64
import json
import struct

import pytest
import websockets

from app.config import settings
from app.voice import live, pipeline, providers

from .conftest import ADMIN
from .test_core import FakeLLM, _msg, _tool_call


def tone(seconds: float, amp: int = 8000, rate: int = 16000) -> bytes:
    n = int(seconds * rate)
    return struct.pack(f"<{n}h", *[amp if i % 40 < 20 else -amp for i in range(n)])


def silence(seconds: float, rate: int = 16000) -> bytes:
    return bytes(int(seconds * rate) * 2)


async def serve(handler, fn):
    async with websockets.serve(handler, "127.0.0.1", 0) as server:
        return await fn(server.sockets[0].getsockname()[1])


async def until(ws, kind: str, seen: list) -> dict:
    while True:
        ev = json.loads(await ws.recv())
        seen.append(ev)
        if ev["type"] == kind:
            return ev


@pytest.fixture
def fast(monkeypatch):
    monkeypatch.setattr(live, "PACE", 0.01)
    monkeypatch.setattr(live, "QUIET_S", 0.3)
    monkeypatch.setattr(live, "NO_ANSWER_S", 1.0)
    monkeypatch.setattr(live, "TIMEOUT_S", 10.0)
    monkeypatch.setattr(settings, "openai_api_key", "sk-test")
    monkeypatch.setattr(settings, "xai_api_key", "xai-test")


# ---------- Audio-Hilfen ----------
def test_wav_roundtrip_and_trim():
    pcm = silence(1.0) + tone(0.5)
    assert live.read_wav(live.to_wav(pcm, 16000)) == pcm
    assert live.read_wav(live.to_wav(pcm, 24000)) is None  # falsche Rate -> klassischer Weg
    assert live.read_wav(b"kein wav") is None
    trimmed = live.trim_leading_silence(pcm)
    assert len(trimmed) == len(tone(0.5)) + len(silence(0.2))  # 0,2 s Vorlauf bleiben


# ---------- xAI Grok Voice ----------
def test_grok_voice_controls_room_devices(client, room, fake_ha, fast, monkeypatch):
    seen: list[dict] = []
    headers = {}
    answer = tone(0.3, rate=24000)

    async def handler(ws):
        headers["auth"] = ws.request.headers["Authorization"]
        headers["path"] = ws.request.path
        await until(ws, "response.create", seen)
        await ws.send(json.dumps({"type": "conversation.item.input_audio_transcription.completed",
                                  "transcript": "Mach das Licht auf 30 Prozent"}))
        for i, entity in enumerate(["light.wohnzimmer", "light.kueche"]):
            await ws.send(json.dumps({"type": "response.function_call_arguments.done", "call_id": f"c{i}",
                                      "name": "control_device",
                                      "arguments": json.dumps({"entity_id": entity, "action": "on", "value": 30})}))
        await ws.send(json.dumps({"type": "response.done"}))
        await until(ws, "response.create", seen)
        await ws.send(json.dumps({"type": "response.output_audio.delta", "delta": base64.b64encode(answer).decode()}))
        await ws.send(json.dumps({"type": "response.output_audio_transcript.delta", "delta": "Licht ist auf 30 Prozent."}))
        await ws.send(json.dumps({"type": "response.done"}))
        await ws.wait_closed()

    async def go(port):
        monkeypatch.setattr(live, "XAI_REALTIME_URL", f"ws://127.0.0.1:{port}/v1/realtime")
        cfg = settings.model_copy(update={"live_provider": "xai"})
        return await live.converse(pcm=silence(0.5) + tone(1.0), room_id=room["id"], session="t1", cfg=cfg)

    turn = asyncio.run(serve(handler, go))
    assert headers == {"auth": "Bearer xai-test", "path": "/v1/realtime?model=grok-voice-3.0"}
    update = seen[0]["session"]
    assert seen[0]["type"] == "session.update"
    assert update["voice"] == "eve" and update["turn_detection"] is None
    assert update["audio"]["input"]["format"] == {"type": "audio/pcm", "rate": 16000}
    assert update["tools"][0]["name"] == "control_device" and update["tools"][0]["type"] == "function"
    assert "light.wohnzimmer" in update["instructions"] and "light.kueche" not in update["instructions"]
    sent = b"".join(base64.b64decode(e["audio"]) for e in seen if e["type"] == "input_audio_buffer.append")
    assert sent == live.trim_leading_silence(silence(0.5) + tone(1.0))
    assert [e["type"] for e in seen if e["type"] != "input_audio_buffer.append"] == [
        "session.update", "input_audio_buffer.commit", "response.create",
        "conversation.item.create", "conversation.item.create", "response.create"]
    outputs = [e["item"]["output"] for e in seen if e["type"] == "conversation.item.create"]
    assert outputs == ["ok", "Fehler: Geraet gehoert nicht zu diesem Raum."]
    assert fake_ha.commands == [("light.wohnzimmer", "on", 30, {})]
    assert turn.transcript == "Mach das Licht auf 30 Prozent"
    assert turn.reply == "Licht ist auf 30 Prozent."
    r = turn.response()
    assert r["mime"] == "audio/wav" and r["actions"] == [{"entity_id": "light.wohnzimmer", "action": "on", "value": 30}]
    assert live.read_wav(base64.b64decode(r["audio_base64"])) is None  # 24 kHz
    assert pipeline.recall("t1")[-1] == {"role": "assistant", "content": "Licht ist auf 30 Prozent."}


def test_grok_voice_error_raises(client, fast, monkeypatch):
    async def handler(ws):
        await ws.recv()
        await ws.send(json.dumps({"type": "error", "error": {"message": "invalid voice"}}))
        await ws.wait_closed()

    async def go(port):
        monkeypatch.setattr(live, "XAI_REALTIME_URL", f"ws://127.0.0.1:{port}/v1/realtime")
        return await live.converse(text="Hallo", cfg=settings.model_copy(update={"live_provider": "xai"}))

    with pytest.raises(live.LiveError, match="invalid voice"):
        asyncio.run(serve(handler, go))


# ---------- OpenAI GPT-Live ----------
def test_gpt_live_delegates_to_hausgeist(client, room, fake_ha, fast, monkeypatch):
    llm = FakeLLM(_msg(tool_calls=[_tool_call("light.wohnzimmer", "on")]),
                  _msg("Das Wohnzimmerlicht ist an."))
    monkeypatch.setattr(pipeline, "llm_client", lambda: (llm, "m"))
    seen: list[dict] = []
    command = tone(0.6)
    answer = tone(0.4)

    async def handler(ws):
        start = await until(ws, "session.start", seen)
        await ws.send(json.dumps({"type": "session.started", "session": {"id": "sess_1"}}))
        got = b""
        while len(got) < len(command):  # Befehl abwarten
            ev = await until(ws, "session.input_audio.append", seen)
            got += base64.b64decode(ev["audio"])
        await ws.send(json.dumps({"type": "session.output_audio.delta",  # „mhm“ waehrend des Sprechens
                                  "delta": base64.b64encode(silence(0.1)).decode()}))
        await ws.send(json.dumps({"type": "session.input_transcript.delta", "delta": "Mach das Licht an",
                                  "start_ms": 0, "end_ms": 600}))
        await asyncio.sleep(0.1)
        await ws.send(json.dumps({"type": "session.delegation.created", "offset_ms": 700,
                                  "delegation": {"id": "item_1", "type": "delegation", "target": "client"}}))
        result = await until(ws, "session.commentary.append", seen)
        await ws.send(json.dumps({"type": "session.commentary.appended", "client_event_id": result["event_id"]}))
        await ws.send(json.dumps({"type": "session.output_transcript.delta", "delta": "Erledigt, das Licht ist an."}))
        for i in range(0, len(answer), 3200):
            await ws.send(json.dumps({"type": "session.output_audio.delta",
                                      "delta": base64.b64encode(answer[i:i + 3200]).decode()}))
        await until(ws, "session.close", seen)
        await ws.send(json.dumps({"type": "session.closed", "reason": "close_requested", "usage": {}}))
        await ws.wait_closed()
        seen.append({"type": "_start", **start})

    async def go(port):
        monkeypatch.setattr(live, "OPENAI_LIVE_URL", f"ws://127.0.0.1:{port}/v1/live/sessions")
        cfg = settings.model_copy(update={"live_provider": "openai"})
        return await live.converse(pcm=silence(1.0) + command, room_id=room["id"], session="t1", cfg=cfg)

    turn = asyncio.run(serve(handler, go))
    start = seen[-1]["session"]
    assert start["model"] == "gpt-live-1" and start["delegation"] == {"type": "client"}
    assert start["audio"] == {"format": {"type": "audio/pcm", "rate": 16000}, "output": {"voice": "marin"}}
    commentary = next(e for e in seen if e["type"] == "session.commentary.append")
    assert commentary["delegation_id"] == "item_1" and commentary["content"] == "Das Wohnzimmerlicht ist an."
    assert llm.calls[0][-1] == {"role": "user", "content": "Mach das Licht an"}
    assert fake_ha.commands == [("light.wohnzimmer", "on", None, {})]
    assert turn.transcript == "Mach das Licht an"
    assert turn.reply == "Erledigt, das Licht ist an."
    assert bytes(turn.pcm) == answer  # ohne das „mhm“
    assert turn.actions == [{"entity_id": "light.wohnzimmer", "action": "on"}]


def test_gpt_live_probe_greets(client, fast, monkeypatch):
    seen: list[dict] = []

    async def handler(ws):
        await until(ws, "session.start", seen)
        await ws.send(json.dumps({"type": "session.started", "session": {"id": "s"}}))
        await asyncio.sleep(0.05)
        await ws.send(json.dumps({"type": "session.output_transcript.delta", "delta": "Hallo, ich bin Hausgeist."}))
        await ws.send(json.dumps({"type": "session.output_audio.delta", "delta": base64.b64encode(tone(0.2)).decode()}))
        await until(ws, "session.close", seen)
        await ws.send(json.dumps({"type": "session.closed", "reason": "close_requested"}))

    async def go(port):
        monkeypatch.setattr(live, "OPENAI_LIVE_URL", f"ws://127.0.0.1:{port}/")
        return await live.probe(settings.model_copy(update={"live_provider": "openai"}))

    turn = asyncio.run(serve(handler, go))
    assert seen[0]["session"]["input"][-1]["role"] == "developer"
    assert turn.reply == "Hallo, ich bin Hausgeist." and len(turn.pcm) == len(tone(0.2))


def test_gpt_live_refuses_text():
    with pytest.raises(live.LiveError):
        asyncio.run(live.converse(text="Hallo", cfg=settings.model_copy(update={"live_provider": "openai"})))


# ---------- Schnittstelle ----------
def test_voice_audio_uses_live_and_falls_back(client, room, fake_ha, fast, monkeypatch):
    client.put("/api/settings", headers=ADMIN, json={"voice_mode": "live", "live_provider": "openai"})
    monkeypatch.setattr(settings, "openai_api_key", "sk-test")  # Speichern hat die Schluessel neu geladen
    wav = live.to_wav(tone(0.5), 16000)
    calls = []

    async def ok(**kw):
        calls.append(kw)
        return live.Turn(transcript="Licht an", reply="Ist an.", pcm=bytearray(tone(0.1)))

    monkeypatch.setattr(live, "converse", ok)
    r = client.post("/api/voice/audio", headers=room["auth"], files={"file": ("befehl.wav", wav, "audio/wav")}).json()
    assert r["reply"] == "Ist an." and r["mime"] == "audio/wav" and r["audio_base64"]
    assert calls[0]["room_id"] == room["id"] and calls[0]["pcm"] == tone(0.5)

    # Live scheitert -> klassischer Weg (Spracherkennung + Sprachmodell), Antwort ohne Stimme
    async def broken(**kw):
        raise live.LiveError("weg")

    async def transcribe(audio, filename, cfg=None):
        return "Licht an"

    monkeypatch.setattr(live, "converse", broken)
    monkeypatch.setattr(providers, "transcribe", transcribe)
    monkeypatch.setattr(pipeline, "llm_client", lambda: (FakeLLM(_msg("Klassisch erledigt.")), "m"))
    r = client.post("/api/voice/audio", headers=room["auth"], files={"file": ("befehl.wav", wav, "audio/wav")}).json()
    assert r["transcript"] == "Licht an" and r["reply"] == "Klassisch erledigt."
    assert "audio_base64" not in r  # ElevenLabs ohne Schluessel: Antwort nur als Text


def test_settings_accept_live_options(client):
    r = client.put("/api/settings", headers=ADMIN, json={
        "voice_mode": "live", "live_provider": "xai", "xai_live_model": "grok-voice-3.0", "xai_voice": "ara",
        "openai_live_voice": "cedar", "stt_provider": "xai", "tts_provider": "xai"})
    assert r.status_code == 200
    v = r.json()
    assert v["voice_mode"]["value"] == "live" and v["live_provider"]["value"] == "xai"
    assert client.put("/api/settings", headers=ADMIN, json={"voice_mode": "duplex"}).status_code == 422
    st = client.get("/api/status", headers=ADMIN).json()["voice"]
    assert st["mode"] == "live" and st["live"] == "xai" and st["live_ok"] is False  # kein xAI-Schluessel
