"""Austauschbare Sprach-Provider: STT, LLM, TTS. Auswahl per .env."""
import httpx
from openai import AsyncOpenAI

from ..config import settings


def llm_client() -> tuple[AsyncOpenAI, str]:
    """OpenAI und xAI (Grok) sprechen beide das OpenAI-Chat-Protokoll."""
    if settings.llm_provider == "xai":
        return (AsyncOpenAI(api_key=settings.xai_api_key, base_url="https://api.x.ai/v1"),
                settings.xai_llm_model)
    return AsyncOpenAI(api_key=settings.openai_api_key), settings.openai_llm_model


async def transcribe(audio: bytes, filename: str) -> str:
    client = AsyncOpenAI(api_key=settings.openai_api_key)
    res = await client.audio.transcriptions.create(
        model="gpt-4o-mini-transcribe", file=(filename, audio))
    return res.text


async def synthesize(text: str) -> tuple[bytes, str]:
    """Gibt (audio_bytes, mime_type) zurueck."""
    if settings.tts_provider == "elevenlabs":
        async with httpx.AsyncClient(timeout=60) as http:
            r = await http.post(
                f"https://api.elevenlabs.io/v1/text-to-speech/{settings.elevenlabs_voice_id}",
                headers={"xi-api-key": settings.elevenlabs_api_key},
                json={"text": text, "model_id": "eleven_multilingual_v2"},
            )
            r.raise_for_status()
            return r.content, "audio/mpeg"
    client = AsyncOpenAI(api_key=settings.openai_api_key)
    res = await client.audio.speech.create(model="gpt-4o-mini-tts", voice="alloy", input=text)
    return res.content, "audio/mpeg"
