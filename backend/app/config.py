from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    ha_url: str = "http://homeassistant.local:8123"
    ha_token: str = ""
    # Notfall-Zugang zur Verwaltung. Normal wird das Passwort bei der Ersteinrichtung in /admin gesetzt.
    admin_key: str = ""

    openai_api_key: str = ""
    xai_api_key: str = ""
    elevenlabs_api_key: str = ""
    elevenlabs_voice_id: str = ""
    elevenlabs_model: str = "eleven_multilingual_v2"

    stt_provider: str = "openai"
    stt_model: str = "gpt-4o-mini-transcribe"
    stt_language: str = "de"
    llm_provider: str = "openai"  # openai | xai | custom (OpenAI-kompatibel, z. B. Ollama)
    openai_llm_model: str = "gpt-4o-mini"
    xai_llm_model: str = "grok-3-mini"
    custom_llm_url: str = ""
    custom_llm_api_key: str = ""
    custom_llm_model: str = ""
    tts_provider: str = "elevenlabs"
    openai_tts_model: str = "gpt-4o-mini-tts"
    openai_tts_voice: str = "alloy"
    assistant_instructions: str = ""  # zusaetzliche Anweisungen fuer den Sprachassistenten

    db_path: str = "/data/hausgeist.db"

    # Update-Hinweis fuer die Tablet-App: neuestes Release aus diesem GitHub-Repo ("" = aus)
    update_repo: str = "gottschalkfelix4-source/hausgeist"


# In der Verwaltung aenderbar; Wert -> geheim? Gespeicherte Werte gehen den Container-Variablen vor.
EDITABLE: dict[str, bool] = {
    "ha_url": False, "ha_token": True,
    "openai_api_key": True, "xai_api_key": True, "elevenlabs_api_key": True,
    "elevenlabs_voice_id": False, "elevenlabs_model": False,
    "stt_provider": False, "stt_model": False, "stt_language": False,
    "llm_provider": False, "openai_llm_model": False, "xai_llm_model": False,
    "custom_llm_url": False, "custom_llm_api_key": True, "custom_llm_model": False,
    "tts_provider": False, "openai_tts_model": False, "openai_tts_voice": False,
    "assistant_instructions": False, "update_repo": False,
}

env_settings = Settings()  # nur Container-Variablen bzw. .env, nie veraendert
settings = Settings()      # gilt im Betrieb: Container-Variablen plus Werte aus der Verwaltung


def apply(overrides: dict[str, str]) -> None:
    """Gespeicherte Werte aus der Datenbank ueber die Container-Variablen legen."""
    for key in EDITABLE:
        setattr(settings, key, overrides[key] if key in overrides else getattr(env_settings, key))


def source(key: str, overrides: dict[str, str]) -> str:
    """Woher der aktuelle Wert kommt: admin (Verwaltung), env (Container) oder default."""
    if key in overrides:
        return "admin"
    if key in env_settings.model_fields_set and getattr(env_settings, key):
        return "env"
    return "default"
