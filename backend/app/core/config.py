"""Application settings loaded from environment variables.

Settings are sourced from the process environment, falling back to a local
`.env` file when present. Unknown variables are ignored so additional infra
config (e.g., logging knobs, deployment hints) can live alongside the app
config without breaking validation.
"""

from __future__ import annotations

from functools import lru_cache

from pydantic import HttpUrl
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Typed view of every backend environment variable.

    Mirrors the keys defined in `backend/.env.example`. Each field name is the
    exact uppercase env var; pydantic-settings does the case-insensitive match.
    """

    # --- Supabase ---
    SUPABASE_URL: HttpUrl
    SUPABASE_SERVICE_ROLE_KEY: str
    SUPABASE_JWT_SECRET: str

    # --- Encryption ---
    # Comma-separated list of Fernet keys, NEWEST FIRST. Each key is a 32-byte
    # url-safe base64 value. `MultiFernet` accepts a list, so we expose the
    # parsed list via `fernet_keys_list` rather than typing the env var as a
    # list (pydantic's list-from-env parsing is JSON-only by default).
    FERNET_KEYS: str

    # --- GitHub OAuth ---
    GITHUB_CLIENT_ID: str = ""
    GITHUB_CLIENT_SECRET: str = ""
    GITHUB_REDIRECT_URI: str = "http://localhost:8000/api/v1/auth/github/callback"

    # --- AI provider defaults ---
    AI_API_KEY_DEFAULT: str = ""
    AI_MODEL_DEFAULT: str = "gpt-4o-mini"
    AI_PROVIDER_BASE_URL_DEFAULT: HttpUrl = HttpUrl("https://api.openai.com/v1")

    model_config = SettingsConfigDict(
        env_file=".env",
        env_file_encoding="utf-8",
        extra="ignore",
        case_sensitive=True,
    )

    @property
    def fernet_keys_list(self) -> list[bytes]:
        """Parsed Fernet keys as bytes, in declaration order (newest first).

        Empty entries (from accidental trailing commas or whitespace) are
        skipped so a value like `"k1, ,k2"` still yields `[b"k1", b"k2"]`.
        """
        return [
            key.encode("utf-8")
            for key in (part.strip() for part in self.FERNET_KEYS.split(","))
            if key
        ]


@lru_cache(maxsize=1)
def get_settings() -> Settings:
    """Return a process-wide cached `Settings` instance.

    The cache is keyless and bounded to one entry, so the first caller pays the
    env-parsing cost and every subsequent caller gets the same object. Tests
    that need to inject overrides should call `get_settings.cache_clear()`.
    """
    return Settings()  # type: ignore[call-arg]
