"""Austauschbare Sprach-Provider: STT, LLM, TTS (Live-Sprachmodelle: live.py). Auswahl in der Verwaltung (oder per Container-Variable).

Alle Funktionen nehmen optional eine eigene Konfiguration, damit die Verwaltung
ungespeicherte Werte ausprobieren kann.
"""
import asyncio

import httpx
from openai import AsyncOpenAI

from ..config import Settings, settings

XAI_URL = "https://api.x.ai/v1"
ELEVENLABS_URL = "https://api.elevenlabs.io/v1"


# Clients bleiben offen, damit nicht jeder Sprachbefehl erst neue TLS-Verbindungen aufbaut.
# Pro Event-Loop, weil Verbindungen an ihren Loop gebunden sind.
_clients: dict[tuple, tuple[asyncio.AbstractEventLoop, object]] = {}


def _cached(key: tuple, make):
    try:
        loop = asyncio.get_running_loop()
    except RuntimeError:
        return make()
    hit = _clients.get(key)
    if hit and hit[0] is loop:
        return hit[1]
    if len(_clients) > 16:
        _clients.clear()
    client = make()
    _clients[key] = (loop, client)
    return client


def _openai(api_key: str, base_url: str | None = None) -> AsyncOpenAI:
    return _cached(("openai", api_key, base_url), lambda: AsyncOpenAI(api_key=api_key, base_url=base_url))


def _http() -> httpx.AsyncClient:
    return _cached(("http",), lambda: httpx.AsyncClient(timeout=60))


def llm_client(cfg: Settings | None = None) -> tuple[AsyncOpenAI, str]:
    """OpenAI, xAI (Grok) und eigene Server wie Ollama sprechen alle das OpenAI-Chat-Protokoll."""
    cfg = cfg or settings
    if cfg.llm_provider == "xai":
        return _openai(cfg.xai_api_key, XAI_URL), cfg.xai_llm_model
    if cfg.llm_provider == "custom":
        # Viele lokale Server brauchen keinen Schluessel, der Client aber einen Wert.
        return _openai(cfg.custom_llm_api_key or "none", cfg.custom_llm_url), cfg.custom_llm_model
    return _openai(cfg.openai_api_key), cfg.openai_llm_model


def _xai_headers(cfg: Settings) -> dict:
    return {"Authorization": f"Bearer {cfg.xai_api_key}"}


async def transcribe(audio: bytes, filename: str, cfg: Settings | None = None) -> str:
    cfg = cfg or settings
    if cfg.stt_provider == "xai":
        data = {"model": cfg.xai_stt_model, "format": "true"}
        if cfg.stt_language:
            data["language"] = cfg.stt_language
        # Die Datei muss das letzte Feld sein; httpx haengt files hinter data an.
        r = await _http().post(f"{XAI_URL}/stt", headers=_xai_headers(cfg), data=data,
                               files={"file": (filename, audio)})
        r.raise_for_status()
        return r.json().get("text", "")
    client = _openai(cfg.openai_api_key)
    extra = {"language": cfg.stt_language} if cfg.stt_language else {}
    res = await client.audio.transcriptions.create(model=cfg.stt_model, file=(filename, audio), **extra)
    return res.text


async def synthesize(text: str, cfg: Settings | None = None) -> tuple[bytes, str]:
    """Gibt (audio_bytes, mime_type) zurueck."""
    cfg = cfg or settings
    if cfg.tts_provider == "elevenlabs":
        # Kleineres MP3 (22 kHz, 32 kbit/s) reicht für Sprache und ist schneller auf dem Tablet.
        r = await _http().post(
            f"{ELEVENLABS_URL}/text-to-speech/{cfg.elevenlabs_voice_id}",
            params={"output_format": "mp3_22050_32"},
            headers={"xi-api-key": cfg.elevenlabs_api_key},
            json={"text": text, "model_id": cfg.elevenlabs_model},
        )
        r.raise_for_status()
        return r.content, "audio/mpeg"
    if cfg.tts_provider == "xai":
        r = await _http().post(f"{XAI_URL}/tts", headers=_xai_headers(cfg),
                               json={"text": text, "voice_id": cfg.xai_voice or "eve",
                                     "language": cfg.stt_language or "auto"})
        r.raise_for_status()
        return r.content, "audio/mpeg"
    client = _openai(cfg.openai_api_key)
    res = await client.audio.speech.create(model=cfg.openai_tts_model, voice=cfg.openai_tts_voice, input=text)
    return res.content, "audio/mpeg"


async def elevenlabs_voices(cfg: Settings | None = None) -> list[dict]:
    cfg = cfg or settings
    async with httpx.AsyncClient(timeout=15) as http:
        r = await http.get(f"{ELEVENLABS_URL}/voices", headers={"xi-api-key": cfg.elevenlabs_api_key})
        r.raise_for_status()
    return sorted(({"voice_id": v["voice_id"], "name": v["name"],
                    "description": ", ".join(str(x) for x in (v.get("labels") or {}).values())}
                   for v in r.json().get("voices", [])), key=lambda v: v["name"].lower())


async def xai_voices(cfg: Settings | None = None) -> list[dict]:
    """Stimmen von Grok; dieselben gibt es beim Vorlesen und bei Grok Voice."""
    cfg = cfg or settings
    async with httpx.AsyncClient(timeout=15) as http:
        r = await http.get(f"{XAI_URL}/tts/voices", headers=_xai_headers(cfg))
        r.raise_for_status()
    return sorted(({"voice_id": v["voice_id"], "name": v.get("name") or v["voice_id"],
                    "description": v.get("language", "")}
                   for v in r.json().get("voices", [])), key=lambda v: v["name"].lower())


def stt_ready(cfg: Settings) -> bool:
    if cfg.stt_provider == "xai":
        return bool(cfg.xai_api_key.strip())
    return bool(cfg.openai_api_key.strip())


def llm_ready(cfg: Settings) -> bool:
    if cfg.llm_provider == "xai":
        return bool(cfg.xai_api_key.strip() and cfg.xai_llm_model.strip())
    if cfg.llm_provider == "custom":
        return bool(cfg.custom_llm_url.strip() and cfg.custom_llm_model.strip())
    return bool(cfg.openai_api_key.strip() and cfg.openai_llm_model.strip())


def tts_ready(cfg: Settings) -> bool:
    if cfg.tts_provider == "elevenlabs":
        return bool(cfg.elevenlabs_api_key.strip() and cfg.elevenlabs_voice_id.strip())
    if cfg.tts_provider == "xai":
        return bool(cfg.xai_api_key.strip())
    return bool(cfg.openai_api_key.strip())


def live_ready(cfg: Settings) -> bool:
    if cfg.live_provider == "xai":
        return bool(cfg.xai_api_key.strip() and cfg.xai_live_model.strip())
    return bool(cfg.openai_api_key.strip() and cfg.openai_live_model.strip())
