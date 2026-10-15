"""Live-Sprachmodelle: Sprache rein, Sprache raus, ohne getrennte Spracherkennung und Stimme.

- OpenAI GPT-Live (gpt-live-1): Vollduplex-Modell. Hausgeist ist sein Backend („client delegation“): Will das
  Modell etwas erledigen, meldet es eine Delegation. Hausgeist fuehrt den Befehl mit dem eingestellten
  Sprachmodell aus (pipeline.run, samt Raumgrenzen) und gibt das Ergebnis zum Aussprechen zurueck.
- xAI Grok Voice (grok-voice-3.0): Realtime-Protokoll, Zug um Zug. Das Modell ruft das Geraete-Werkzeug selbst
  auf; pipeline.execute wacht ueber die Raumgrenzen.

Die Tablets nehmen einen Befehl am Stueck auf. Pro Befehl oeffnet Hausgeist deshalb eine kurze Sitzung, spielt
die Aufnahme ein und sammelt die gesprochene Antwort als WAV.
"""
import asyncio
import base64
import io
import json
import logging
import math
import struct
import time
import wave
from dataclasses import dataclass, field
from urllib.parse import quote

import websockets

from ..config import Settings, settings
from . import pipeline
from .providers import llm_ready

log = logging.getLogger(__name__)

OPENAI_LIVE_URL = "wss://api.openai.com/v1/live/sessions"
XAI_REALTIME_URL = "wss://api.x.ai/v1/realtime"

RATE = 16000        # Aufnahme der Tablets: PCM16, mono, 16 kHz
XAI_OUT_RATE = 24000
CHUNK_S = 0.1       # Audio in 100-ms-Stuecken einspielen
PACE = 1.0          # GPT-Live erwartet Mikrofon-Tempo (1.0 = Echtzeit); Tests drehen schneller
QUIET_S = 1.6       # GPT-Live meldet kein Ende: so lange keine neue Sprachausgabe = Antwort fertig
NO_ANSWER_S = 8.0   # ... und so lange nach dem Befehl ganz ohne Antwort = aufgeben
TIMEOUT_S = 45.0
GREETING = "Begruesse den Nutzer in einem kurzen Satz auf Deutsch und stell dich als Hausgeist vor."


class LiveError(RuntimeError):
    pass


@dataclass
class Turn:
    transcript: str = ""
    reply: str = ""
    actions: list[dict] = field(default_factory=list)
    pcm: bytearray = field(default_factory=bytearray)
    rate: int = RATE

    def response(self) -> dict:
        out = {"transcript": self.transcript, "reply": self.reply, "actions": self.actions}
        if self.pcm:
            out |= {"audio_base64": base64.b64encode(to_wav(bytes(self.pcm), self.rate)).decode(), "mime": "audio/wav"}
        return out


# ---------- Audio ----------
def read_wav(data: bytes) -> bytes | None:
    """PCM16 mono 16 kHz aus einer WAV-Datei, wie sie die Tablets schicken; sonst None."""
    try:
        with wave.open(io.BytesIO(data)) as w:
            if w.getnchannels() != 1 or w.getsampwidth() != 2 or w.getframerate() != RATE:
                return None
            return w.readframes(w.getnframes())
    except (wave.Error, EOFError):
        return None


def to_wav(pcm: bytes, rate: int) -> bytes:
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w:
        w.setnchannels(1)
        w.setsampwidth(2)
        w.setframerate(rate)
        w.writeframes(pcm)
    return buf.getvalue()


def _db(block: bytes) -> float:
    n = len(block) // 2
    if not n:
        return -100.0
    samples = struct.unpack(f"<{n}h", block[: n * 2])
    rms = math.sqrt(sum(v * v for v in samples) / n) / 32768
    return 20 * math.log10(rms) if rms > 0 else -100.0


def trim_leading_silence(pcm: bytes, keep_s: float = 0.2) -> bytes:
    """Stille vor dem ersten Wort abschneiden: GPT-Live hoert in Echtzeit, jede Sekunde Stille kostet Wartezeit."""
    step = int(RATE * CHUNK_S) * 2
    blocks = [pcm[i:i + step] for i in range(0, len(pcm), step)]
    levels = [_db(b) for b in blocks]
    if not levels:
        return pcm
    loud = max(levels)
    first = next((i for i, d in enumerate(levels) if d > max(loud - 20, -50)), 0)
    start = max(0, first - round(keep_s / CHUNK_S))
    return pcm[start * step:]


# ---------- gemeinsam ----------
def _instructions() -> str:
    text = ("Du bist Hausgeist, der Sprachassistent eines Smart Homes. Sprich Deutsch, kurz und natuerlich, "
            "in ein bis zwei Saetzen. Wenn der Nutzer im Haus etwas schalten, einstellen oder wissen will "
            "(Licht, Heizung, Rollos, Steckdosen, Musik, Zustaende von Geraeten), delegiere das immer an das "
            "Backend und sag danach nur das Ergebnis. Erfinde nie, ob etwas geklappt hat.")
    if settings.assistant_instructions.strip():
        text += "\n\nZusaetzliche Anweisungen des Hausherrn:\n" + settings.assistant_instructions.strip()
    return text


def _event_error(ev: dict) -> str:
    err = ev.get("error") or {}
    return str(err.get("message") or err.get("code") or ev)[:300]


async def _connect(url: str, key: str):
    return await websockets.connect(url, additional_headers={"Authorization": f"Bearer {key}"},
                                    max_size=None, open_timeout=10, close_timeout=3)


# ---------- OpenAI GPT-Live ----------
class _GptLive:
    def __init__(self, ws, pcm: bytes, room_id: str | None, session: str | None) -> None:
        self.ws = ws
        self.pcm = pcm
        self.room_id = room_id
        self.session = session
        self.turn = Turn(rate=RATE)
        self.heard: list[str] = []
        self.input_done_at: float | None = None
        self.last_audio_at = 0.0
        self.answered_at: float | None = None  # Ergebnis einer Delegation zurueckgegeben
        self.pending = 0
        self.delegated = 0
        self.closing = False
        self.tasks: set[asyncio.Task] = set()

    async def send(self, ev: dict) -> None:
        await self.ws.send(json.dumps(ev))

    async def stream_audio(self) -> None:
        """Befehl im Mikrofon-Tempo einspielen, danach Stille wie ein ruhiger Raum."""
        step = int(RATE * CHUNK_S) * 2
        chunks = [self.pcm[i:i + step] for i in range(0, len(self.pcm), step)]
        silence = bytes(step)
        start = time.monotonic()
        n = 0
        while not self.closing:
            chunk = chunks[n] if n < len(chunks) else silence
            await self.send({"type": "session.input_audio.append", "audio": base64.b64encode(chunk).decode()})
            n += 1
            if n == len(chunks) + 3 and self.input_done_at is None:  # plus 0,3 s Pause
                self.input_done_at = time.monotonic()
            await asyncio.sleep(max(0.0, start + n * CHUNK_S * PACE - time.monotonic()))

    async def delegate(self, delegation_id: str) -> None:
        """Hausgeist als Backend: Befehl mit dem eingestellten Sprachmodell ausfuehren."""
        try:
            while self.input_done_at is None and not self.closing:
                await asyncio.sleep(0.05)
            await asyncio.sleep(0.3)  # letzte Mitschrift abwarten
            text = "".join(self.heard).strip()
            if not text:
                result = "Ich habe den Befehl akustisch nicht verstanden."
            elif not llm_ready(settings):
                result = "Fuer die Geraetesteuerung ist kein Sprachmodell eingerichtet."
            else:
                r = await pipeline.run(text, self.room_id, self.session)
                self.turn.actions.extend(r["actions"])
                result = r["reply"] or "Erledigt."
        except Exception as e:  # noqa: BLE001
            log.warning("GPT-Live: Befehl fehlgeschlagen: %s", e)
            result = "Das hat leider nicht geklappt."
        try:
            await self.send({"type": "session.commentary.append", "event_id": f"result_{delegation_id}",
                             "delegation_id": delegation_id, "content": result[:1500]})
        finally:
            self.answered_at = time.monotonic()
            self.pending -= 1

    def finished(self, now: float) -> bool:
        if self.input_done_at is None or self.pending:
            return False
        if self.turn.pcm:
            spoke_after_answer = self.answered_at is None or self.last_audio_at > self.answered_at
            return spoke_after_answer and now - self.last_audio_at > QUIET_S
        waited_since = self.answered_at or self.input_done_at
        return now - waited_since > NO_ANSWER_S

    def on_event(self, ev: dict) -> None:
        t = ev.get("type")
        now = time.monotonic()
        if t == "session.input_transcript.delta":
            self.heard.append(ev.get("delta", ""))
        elif t == "session.output_audio.delta":
            # Nur was nach dem Befehl kommt; ein „mhm“ waehrend des Sprechens gehoert nicht zur Antwort.
            if self.input_done_at is not None:
                self.turn.pcm += base64.b64decode(ev.get("delta", ""))
                self.last_audio_at = now
        elif t == "session.output_transcript.delta":
            if self.input_done_at is not None:
                self.turn.reply += ev.get("delta", "")
        elif t == "session.delegation.created":
            d = ev.get("delegation") or {}
            if d.get("target", "client") == "client" and d.get("id"):
                self.pending += 1
                self.delegated += 1
                task = asyncio.create_task(self.delegate(d["id"]))
                self.tasks.add(task)
                task.add_done_callback(self.tasks.discard)
        elif t == "error":
            log.warning("GPT-Live meldet: %s", _event_error(ev))

    async def run(self) -> Turn:
        deadline = time.monotonic() + TIMEOUT_S
        sender: asyncio.Task | None = None
        try:
            while True:
                now = time.monotonic()
                if now > deadline:
                    break
                try:
                    raw = await asyncio.wait_for(self.ws.recv(), timeout=0.1)
                except TimeoutError:
                    raw = None
                if raw is not None and not isinstance(raw, bytes):
                    ev = json.loads(raw)
                    if ev.get("type") == "session.started":
                        sender = asyncio.create_task(self.stream_audio())
                    elif ev.get("type") == "error" and sender is None:
                        raise LiveError(_event_error(ev))
                    elif ev.get("type") == "session.closed":
                        break
                    else:
                        self.on_event(ev)
                if sender is not None and self.finished(time.monotonic()):
                    break
        finally:
            self.closing = True
            for task in [sender, *self.tasks]:
                if task:
                    task.cancel()
            await self.close()
        self.turn.transcript = "".join(self.heard).strip()
        self.turn.reply = self.turn.reply.strip()
        if not self.turn.pcm and not self.turn.reply:
            raise LiveError("GPT-Live hat nicht geantwortet.")
        if not self.delegated and self.turn.transcript:
            pipeline.remember(self.session, self.turn.transcript, self.turn.reply)
        return self.turn

    async def close(self) -> None:
        """Sitzung sauber beenden, damit nicht weiter abgerechnet wird."""
        try:
            await self.send({"type": "session.close"})
            end = time.monotonic() + 3
            while time.monotonic() < end:
                raw = await asyncio.wait_for(self.ws.recv(), timeout=end - time.monotonic())
                if not isinstance(raw, bytes) and json.loads(raw).get("type") == "session.closed":
                    break
        except Exception:  # noqa: BLE001
            pass


def _gpt_live_start(cfg: Settings, session: str | None, greet: bool) -> dict:
    history = [{"type": "message", "role": m["role"],
                "content": [{"type": "input_text" if m["role"] == "user" else "output_text", "text": m["content"]}]}
               for m in pipeline.recall(session)]
    if greet:
        history.append({"type": "message", "role": "developer", "content": [{"type": "input_text", "text": GREETING}]})
    return {"type": "session.start", "event_id": "start", "session": {
        "model": cfg.openai_live_model,
        "instructions": _instructions(),
        "input": history,
        "audio": {"format": {"type": "audio/pcm", "rate": RATE}, "output": {"voice": cfg.openai_live_voice or "marin"}},
        "delegation": {"type": "client"},
    }}


async def _gpt_live(pcm: bytes, room_id: str | None, session: str | None, cfg: Settings, greet: bool = False) -> Turn:
    ws = await _connect(OPENAI_LIVE_URL, cfg.openai_api_key)
    try:
        await ws.send(json.dumps(_gpt_live_start(cfg, session, greet)))
        return await _GptLive(ws, pcm, room_id, session).run()
    finally:
        await ws.close()


# ---------- xAI Grok Voice ----------
def _realtime_tool() -> dict:
    fn = pipeline.TOOLS[0]["function"]
    return {"type": "function", "name": fn["name"], "description": fn["description"], "parameters": fn["parameters"]}


async def _grok(pcm: bytes | None, text: str | None, room_id: str | None, session: str | None,
                cfg: Settings) -> Turn:
    system, allowed = await pipeline.prompt(room_id)
    history = pipeline.recall(session)
    if history:
        system += "\n\nBisheriges Gespraech:\n" + "\n".join(
            f"{'Nutzer' if m['role'] == 'user' else 'Hausgeist'}: {m['content']}" for m in history)
    transcription = {"model": "grok-transcribe"}
    if cfg.stt_language:
        transcription["language_hint"] = cfg.stt_language
    turn = Turn(transcript=text or "", rate=XAI_OUT_RATE)
    ws = await _connect(f"{XAI_REALTIME_URL}?model={quote(cfg.xai_live_model)}", cfg.xai_api_key)

    async def send(ev: dict) -> None:
        await ws.send(json.dumps(ev))

    try:
        await send({"type": "session.update", "session": {
            "instructions": system,
            "voice": cfg.xai_live_voice or "eve",
            "turn_detection": None,
            "audio": {"input": {"format": {"type": "audio/pcm", "rate": RATE}, "transcription": transcription},
                      "output": {"format": {"type": "audio/pcm", "rate": XAI_OUT_RATE}}},
            "tools": [_realtime_tool()],
        }})
        if pcm:
            step = RATE * 2  # 1 s pro Nachricht
            for i in range(0, len(pcm), step):
                await send({"type": "input_audio_buffer.append", "audio": base64.b64encode(pcm[i:i + step]).decode()})
            await send({"type": "input_audio_buffer.commit"})
        else:
            await send({"type": "conversation.item.create", "item": {
                "type": "message", "role": "user", "content": [{"type": "input_text", "text": text or GREETING}]}})
        await send({"type": "response.create"})

        outputs: list[tuple[str, str]] = []
        deadline = time.monotonic() + TIMEOUT_S
        rounds = 0
        while True:
            left = deadline - time.monotonic()
            if left <= 0:
                raise LiveError("Grok Voice hat nicht rechtzeitig geantwortet.")
            raw = await asyncio.wait_for(ws.recv(), timeout=left)
            if isinstance(raw, bytes):
                turn.pcm += raw
                continue
            ev = json.loads(raw)
            t = ev.get("type")
            if t in ("response.output_audio.delta", "response.audio.delta"):
                turn.pcm += base64.b64decode(ev.get("delta", ""))
            elif t in ("response.output_audio_transcript.delta", "response.audio_transcript.delta"):
                turn.reply += ev.get("delta", "")
            elif t in ("conversation.item.input_audio_transcription.completed",
                       "conversation.item.input_audio_transcription.updated"):
                turn.transcript = ev.get("transcript") or turn.transcript
            elif t == "response.function_call_arguments.done":
                try:
                    args = json.loads(ev.get("arguments") or "{}")
                except ValueError:
                    args = {}
                outputs.append((ev.get("call_id", ""), await pipeline.execute(args, allowed, turn.actions)))
            elif t == "response.done":
                if not outputs or rounds >= 4:
                    break
                rounds += 1
                for call_id, output in outputs:
                    await send({"type": "conversation.item.create",
                                "item": {"type": "function_call_output", "call_id": call_id, "output": output}})
                outputs.clear()
                await send({"type": "response.create"})
            elif t == "error":
                raise LiveError(_event_error(ev))
    finally:
        await ws.close()
    turn.transcript = turn.transcript.strip()
    turn.reply = turn.reply.strip()
    if turn.transcript:
        pipeline.remember(session, turn.transcript, turn.reply)
    return turn


# ---------- Einstieg ----------
async def converse(*, pcm: bytes | None = None, text: str | None = None, room_id: str | None = None,
                   session: str | None = None, cfg: Settings | None = None) -> Turn:
    """Ein Befehl als Aufnahme (PCM16 mono 16 kHz) oder Text; Antwort als Sprache."""
    cfg = cfg or settings
    if cfg.live_provider == "xai":
        return await _grok(trim_leading_silence(pcm) if pcm else None, text, room_id, session, cfg)
    if pcm is None:
        raise LiveError("GPT-Live versteht nur gesprochene Befehle.")
    return await _gpt_live(trim_leading_silence(pcm), room_id, session, cfg)


async def probe(cfg: Settings) -> Turn:
    """Verbindungstest aus der Verwaltung: Das Modell stellt sich kurz vor."""
    if cfg.live_provider == "xai":
        return await _grok(None, GREETING, None, None, cfg)
    return await _gpt_live(b"", None, None, cfg, greet=True)
