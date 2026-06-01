"""Service-role Supabase client singleton.

The backend talks to Supabase Postgres through the service-role key, which
bypasses RLS. Application code is responsible for scoping every query to the
authenticated user via `user_id` filters. The service-role key MUST never be
exposed to the Flutter app or any client-bound response.
"""

from __future__ import annotations

from supabase import Client, create_client

from app.core.config import get_settings

# Module-level singleton. Lazily initialized on first `get_supabase()` call so
# importing this module (e.g., during test collection) doesn't require the env
# vars to be set.
_client: Client | None = None


def get_supabase() -> Client:
    """Return the process-wide service-role Supabase client.

    The first call constructs the client from `SUPABASE_URL` +
    `SUPABASE_SERVICE_ROLE_KEY`; subsequent calls reuse the same instance.
    `HttpUrl` is cast to `str` because the supabase-py constructor expects a
    plain string URL.
    """
    global _client
    if _client is None:
        settings = get_settings()
        _client = create_client(
            str(settings.SUPABASE_URL),
            settings.SUPABASE_SERVICE_ROLE_KEY,
        )
    return _client


def reset_supabase_client() -> None:
    """Drop the cached client. Intended for tests that swap settings."""
    global _client
    _client = None
