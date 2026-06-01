"""Property test: no backend response body ever contains the AI key.

Validates **Property 17** (design.md): for any AI key stored via
``PUT /profile/settings``, the key substring is absent from every
response body returned by the API.

Validates **Requirement 6.5**:

    "The decrypted AI key SHALL NOT appear in any Backend_API response body."

The property is exercised at the HTTP boundary: a TestClient boots the
production FastAPI app, stores a Hypothesis-generated key via
``PUT /profile/settings``, then hits every endpoint and asserts the key
substring is absent from every response body.
"""

import secrets
import time
from collections.abc import Iterator
from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

import pytest
from fastapi.testclient import TestClient
from hypothesis import HealthCheck, given, settings as h_settings, strategies as st
from jose import jwt

JWT_SECRET = "test-no-key-secret-" + secrets.token_urlsafe(16)
FERNET_KEY = "Mj6ttjVWrIA5KiFpYnsot8BVpzPB8ABFZzlD_im4aAM="
AUDIENCE = "authenticated"

PROPERTY_SETTINGS = h_settings(
    max_examples=30,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
    deadline=None,
)


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Provide the env required by `Settings` and reset cached singletons."""
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-role-placeholder")
    monkeypatch.setenv("SUPABASE_JWT_SECRET", JWT_SECRET)
    monkeypatch.setenv("FERNET_KEYS", FERNET_KEY)
    monkeypatch.setenv("AI_MODEL_DEFAULT", "gpt-4o-mini")
    monkeypatch.setenv("AI_PROVIDER_BASE_URL_DEFAULT", "https://api.openai.com/v1")

    from app.core.config import get_settings
    from app.core.encryption import get_encryption_service

    get_settings.cache_clear()
    get_encryption_service.cache_clear()
    try:
        yield
    finally:
        get_settings.cache_clear()
        get_encryption_service.cache_clear()


def _mint_token(subject: str | None = None) -> str:
    """Mint a valid Supabase-style HS256 JWT for the test app."""
    now = int(time.time())
    return jwt.encode(
        {
            "sub": subject or str(uuid4()),
            "aud": AUDIENCE,
            "iat": now,
            "exp": now + 3600,
            "email": "user@example.com",
        },
        JWT_SECRET,
        algorithm="HS256",
    )


def _build_app(monkeypatch: pytest.MonkeyPatch) -> tuple[Any, dict[str, Any]]:
    """Boot the production FastAPI app with service layer stubbed.

    Returns the app plus a mutable state dict that tracks the stored
    settings so the property test can verify key absence.
    """
    # Mutable state shared across all stubs for a single test invocation.
    state: dict[str, Any] = {
        "settings_store": {},  # user_id -> SettingsOut
    }

    def fake_get_profile(user_id: UUID, **_kwargs):
        from app.schemas.profile import ProfileOut

        return ProfileOut(
            id=user_id,
            email="user@example.com",
            full_name=None,
            github_url="https://github.com/example",
            linkedin_url="https://linkedin.com/in/example",
            goal="Become a Senior Backend Engineer",
            created_at=datetime.now(tz=timezone.utc),
        )

    def fake_patch_profile(user_id: UUID, patch, **_kwargs):
        from app.schemas.profile import ProfileOut

        return ProfileOut(
            id=user_id,
            email="user@example.com",
            full_name=None,
            github_url="https://github.com/example",
            linkedin_url="https://linkedin.com/in/example",
            goal="Become a Senior Backend Engineer",
            created_at=datetime.now(tz=timezone.utc),
        )

    def fake_get_settings(user_id: UUID, **_kwargs):
        from app.schemas.settings import SettingsOut

        stored = state["settings_store"].get(str(user_id))
        if stored:
            return stored
        return SettingsOut(
            has_ai_key=False,
            ai_provider_base_url="https://api.openai.com/v1",
        )

    def fake_put_settings(user_id: UUID, payload, **_kwargs):
        from app.schemas.settings import SettingsOut

        out = SettingsOut(
            has_ai_key=True,
            ai_provider_base_url=payload.ai_provider_base_url,
        )
        state["settings_store"][str(user_id)] = out
        return out

    def fake_get_latest(user_id: UUID, **_kwargs):
        return None

    async def fake_analysis_run(user_id: UUID, request, **_kwargs):
        from app.services.settings_service import MissingAIKey

        # Simulate the 412 when no key is stored (the key was stored via
        # put_settings but the analysis service would need to decrypt it;
        # we just raise MissingAIKey to keep the stub simple and safe).
        raise MissingAIKey("ai_key_missing")

    from app.services import analysis_service, profile_service, settings_service

    monkeypatch.setattr(profile_service, "get_profile", fake_get_profile)
    monkeypatch.setattr(profile_service, "patch_profile", fake_patch_profile)
    monkeypatch.setattr(settings_service, "get_settings", fake_get_settings)
    monkeypatch.setattr(settings_service, "put_settings", fake_put_settings)
    monkeypatch.setattr(analysis_service, "get_latest", fake_get_latest)
    monkeypatch.setattr(analysis_service, "run", fake_analysis_run)

    from app.main import create_app

    return create_app(), state


# AI key strategy: min_length=8 matches SettingsIn validation, max_length=128
_ai_key_strategy = st.text(
    alphabet=st.characters(whitelist_categories=("L", "N", "P", "S")),
    min_size=8,
    max_size=128,
).filter(lambda s: len(s.strip()) >= 8)


@PROPERTY_SETTINGS
@given(ai_key=_ai_key_strategy)
def test_no_response_body_contains_ai_key(
    monkeypatch: pytest.MonkeyPatch,
    ai_key: str,
) -> None:
    """Validates Requirement 6.5 / Property 17.

    For any AI key:
    1. Store it via PUT /profile/settings.
    2. Hit every endpoint.
    3. Assert the key substring is absent from every response body.
    """
    app, state = _build_app(monkeypatch)
    user_id = uuid4()
    token = _mint_token(str(user_id))
    headers = {"Authorization": f"Bearer {token}"}

    client = TestClient(app)

    # Step 1: Store the AI key via PUT /profile/settings
    put_resp = client.put(
        "/api/v1/profile/settings",
        headers=headers,
        json={
            "ai_key": ai_key,
            "ai_provider_base_url": "https://api.openai.com/v1",
        },
    )
    assert put_resp.status_code == 200, put_resp.text
    # Assert key not in PUT response
    assert ai_key not in put_resp.text, (
        f"AI key found in PUT /profile/settings response"
    )

    # Step 2: GET /profile/me
    get_me_resp = client.get("/api/v1/profile/me", headers=headers)
    assert get_me_resp.status_code == 200, get_me_resp.text
    assert ai_key not in get_me_resp.text, (
        f"AI key found in GET /profile/me response"
    )

    # Step 3: GET /profile/settings
    get_settings_resp = client.get("/api/v1/profile/settings", headers=headers)
    assert get_settings_resp.status_code == 200, get_settings_resp.text
    assert ai_key not in get_settings_resp.text, (
        f"AI key found in GET /profile/settings response"
    )

    # Step 4: POST /analysis/run — will return 412 (MissingAIKey) but body
    # must not contain the key regardless of the error shape.
    run_resp = client.post(
        "/api/v1/analysis/run",
        headers=headers,
        json={
            "github_url": "https://github.com/example",
            "linkedin_url": "https://linkedin.com/in/example",
            "goal": "Become a Senior Backend Engineer",
        },
    )
    assert ai_key not in run_resp.text, (
        f"AI key found in POST /analysis/run response"
    )

    # Step 5: GET /analysis/latest — will be 204 (no analysis yet); key must
    # not appear.
    latest_resp = client.get("/api/v1/analysis/latest", headers=headers)
    assert ai_key not in latest_resp.text, (
        f"AI key found in GET /analysis/latest response"
    )
