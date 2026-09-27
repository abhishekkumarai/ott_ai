import logging
import os
from functools import lru_cache
from pathlib import Path
from urllib.parse import urlsplit, urlunsplit

from pydantic import field_validator
from pydantic_settings import BaseSettings, SettingsConfigDict

DB_NAME = "ott_ai_db"
log = logging.getLogger("ott_ai")


def _default_db_url() -> str:
    """Fall back to the machine DATABASE_URL (which has no dbname) + ott_ai_db."""
    raw = os.environ.get("DATABASE_URL", "")
    if not raw:
        return ""
    parts = urlsplit(raw)
    path = parts.path if parts.path not in ("", "/") else f"/{DB_NAME}"
    return urlunsplit(("postgresql+asyncpg", parts.netloc, path, parts.query, ""))


class Settings(BaseSettings):
    model_config = SettingsConfigDict(
        env_prefix="OTT_",
        env_file=Path(__file__).resolve().parents[2] / ".env",
        extra="ignore",
    )

    env: str = "dev"
    database_url: str = ""
    expected_db_name: str = DB_NAME
    jwt_secret: str
    access_token_minutes: int = 15
    refresh_token_days: int = 14
    youtube_api_key: str = ""
    ollama_url: str = "http://localhost:11434"
    allowed_models: list[str] = ["llama3.2:3b", "qwen3.5:4b", "llama3.1:latest"]
    default_model: str = "llama3.2:3b"
    embed_model: str = "nomic-embed-text:latest"
    # Recommendations (the Recommended rail) only come from these catalog topics,
    # matched case-insensitively; an empty list allows any topic.
    recommend_topics: list[str] = ["LLMs", "machine learning", "data structures"]
    llm_timeout_s: float = 25.0
    # Upper bound for the context window sent as num_ctx (and shown in the app).
    llm_num_ctx: int = 4096
    max_login_failures: int = 5
    lockout_minutes: int = 15
    cors_origins: list[str] = []

    @field_validator("jwt_secret")
    @classmethod
    def _secret_len(cls, v: str) -> str:
        if len(v) < 32:
            raise ValueError("OTT_JWT_SECRET must be at least 32 characters")
        return v

    @property
    def is_prod(self) -> bool:
        return self.env == "prod"

    @property
    def db_url(self) -> str:
        url = self.database_url or _default_db_url()
        if not url:
            raise RuntimeError("No database URL: set OTT_DATABASE_URL or DATABASE_URL")
        name = urlsplit(url).path.lstrip("/")
        if name != self.expected_db_name:
            raise RuntimeError(
                f"Refusing to start: database is '{name or '<none>'}', "
                f"expected '{self.expected_db_name}'"
            )
        return url


@lru_cache
def get_settings() -> Settings:
    return Settings()
