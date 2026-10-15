from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

    ha_url: str = "http://homeassistant.local:8123"
    ha_token: str = ""
    admin_key: str = "change-me"

    openai_api_key: str = ""
    xai_api_key: str = ""
    elevenlabs_api_key: str = ""
    elevenlabs_voice_id: str = ""

    stt_provider: str = "openai"
    llm_provider: str = "openai"
    tts_provider: str = "elevenlabs"
    openai_llm_model: str = "gpt-4o-mini"
    xai_llm_model: str = "grok-3-mini"

    db_path: str = "/data/hausgeist.db"


settings = Settings()
