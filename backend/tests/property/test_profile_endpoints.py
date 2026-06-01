"""Property tests for the profile and settings endpoints.

Validates three universal invariants over the HTTP boundary of the v1
profile router:

* **Property 3** - PATCH /profile/me write-then-read identity. For any
  valid subset ``P`` of the writable fields, after the patch is applied
  ``GET /profile/me`` returns the prior profile merged with ``P``.
  Validates Requirements 2.2, 2.3.
* **Property 4** - non-HTTPS profile URLs are rejected at the boundary
  with HTTP 422 and a field-level error. Validates Requirement 2.4.
* **Property 19** - non-HTTPS provider base URLs on PUT /profile/settings
  are rejected with HTTP 422. Validates Requirement 6.7.

Tests run hermetically: a TestClient boots the production FastAPI app,
the JWT dependency is exercised end-to-end against a Hypothesis-generated
subject (a fresh UUID per example, signed with a unique-per-module test
secret), and the underlying service modules are stubbed via monkeypatch
so we never touch real Supabase or HTTP traffic.
"""

# NOTE: deliberately no ``from __future__ import annotations`` -
# FastAPI's runtime annotation introspection breaks on stringified
# ``CurrentUser`` in route handlers, and we boot the real router below.

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

JWT_SECRET = "test-profile-secret-" + secrets.token_urlsafe(16)
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


def _mint_token(subject=None):
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


def _baseline_profile(user_id: UUID) -> dict[str, Any]:
    """A complete profile row dict the stubs return for `get_profile`."""
    return {
        "id": str(user_id),
        "email": "user@example.com",
        "full_name": None,
        "github_url": "https://github.com/example",
        "linkedin_url": "https://linkedin.com/in/example",
        "goal": "Become a Senior Backend Engineer",
        "created_at": datetime.now(tz=timezone.utc).isoformat(),
    }


def _build_app(monkeypatch: pytest.MonkeyPatch) -> tuple[Any, dict[str, Any]]:
    """Boot the production FastAPI app with the service layer stubbed.

    Returns the app plus a mutable in-memory store so tests can seed and
    inspect the simulated profile state.
    """
    # Seed: one row per user_id encountered. Tests only ever exercise one
    # user, but a dict keeps the shape future-proof.
    state: dict[str, dict[str, Any]] = {}

    def fake_get_profile(user_id: UUID, **_kwargs):
        from app.schemas.profile import ProfileOut
        from app.services import profile_service

        row = state.get(str(user_id))
        if row is None:
            raise profile_service.ProfileNotFound(str(user_id))
        return ProfileOut.model_validate(row)

    def fake_patch_profile(user_id: UUID, patch, **_kwargs):
        from app.schemas.profile import ProfileOut
        from app.services import profile_service

        row = state.get(str(user_id))
        if row is None:
            raise profile_service.ProfileNotFound(str(user_id))
        # Mirror Pydantic's PATCH semantics: only apply explicitly-set
        # fields, serialize URL types as strings.
        update = patch.model_dump(exclude_unset=True, mode="json")
        row.update(update)
        return ProfileOut.model_validate(row)

    def fake_get_settings(user_id: UUID, **_kwargs):
        from app.schemas.settings import SettingsOut

        return SettingsOut(
            has_ai_key=False,
            ai_provider_base_url="https://api.openai.com/v1",
        )

    def fake_put_settings(user_id: UUID, payload, **_kwargs):
        from app.schemas.settings import SettingsOut

        return SettingsOut(
            has_ai_key=True,
            ai_provider_base_url=payload.ai_provider_base_url,
        )

    from app.services import profile_service, settings_service

    monkeypatch.setattr(profile_service, "get_profile", fake_get_profile)
    monkeypatch.setattr(profile_service, "patch_profile", fake_patch_profile)
    monkeypatch.setattr(settings_service, "get_settings", fake_get_settings)
    monkeypatch.setattr(settings_service, "put_settings", fake_put_settings)

    from app.main import create_app

    return create_app(), state


# ---------------------------------------------------------------------------
# Property 3 — write-then-read identity for PATCH /profile/me.
# ---------------------------------------------------------------------------


# Generators bounded to the writable fields and the schema's URL/length rules.
_writable_https_url = st.sampled_from(
    [
        "https://github.com/abc",
        "https://github.com/another-user",
        "https://linkedin.com/in/abc",
        "https://linkedin.com/in/another",
    ]
)
_goal_strategy = st.text(min_size=1, max_size=500).filter(lambda s: len(s.strip()) > 0)
_patch_strategy = st.fixed_dictionaries(
    {},
    optional={
        "github_url": _writable_https_url,
        "linkedin_url": _writable_https_url,
        "goal": _goal_strategy,
    },
).filter(lambda d: len(d) > 0)


@PROPERTY_SETTINGS
@given(patch=_patch_strategy)
def test_patch_then_get_returns_prior_merged_with_patch(
    monkeypatch: pytest.MonkeyPatch, patch: dict[str, Any]
) -> None:
    """Validates Requirements 2.2, 2.3 / Property 3."""
    app, state = _build_app(monkeypatch)
    user_id = uuid4()
    state[str(user_id)] = _baseline_profile(user_id)
    token = _mint_token(str(user_id))
    headers = {"Authorization": f"Bearer {token}"}

    # Capture the prior profile so we can assert "prior merged with P".
    prior = dict(state[str(user_id)])

    client = TestClient(app)

    # Act: PATCH then GET.
    patch_response = client.patch("/api/v1/profile/me", headers=headers, json=patch)
    assert patch_response.status_code == 200, patch_response.text

    get_response = client.get("/api/v1/profile/me", headers=headers)
    assert get_response.status_code == 200
    after = get_response.json()

    # Compare the relevant fields against `prior merged with patch`.
    expected = dict(prior)
    expected.update(patch)
    for key, value in expected.items():
        if key == "created_at":
            continue
        actual = after.get(key)
        # Pydantic may render URLs with trailing slashes; compare normalized.
        if isinstance(value, str) and value.startswith("https://"):
            assert str(actual).rstrip("/") == value.rstrip("/")
        else:
            assert actual == value, (key, actual, value)


# ---------------------------------------------------------------------------
# Property 4 — non-HTTPS profile URLs yield 422.
# ---------------------------------------------------------------------------


_non_https_strategy = st.one_of(
    st.sampled_from(
        [
            "http://github.com/abc",
            "http://linkedin.com/in/abc",
            "ftp://github.com/abc",
            "not a url",
            "://example.com",
        ]
    ),
    st.text(min_size=1, max_size=32).filter(lambda s: not s.startswith("https://")),
)


@PROPERTY_SETTINGS
@given(field=st.sampled_from(["github_url", "linkedin_url"]), bad_url=_non_https_strategy)
def test_non_https_profile_urls_return_422(
    monkeypatch: pytest.MonkeyPatch, field: str, bad_url: str
) -> None:
    """Validates Requirement 2.4 / Property 4."""
    app, state = _build_app(monkeypatch)
    user_id = uuid4()
    state[str(user_id)] = _baseline_profile(user_id)
    token = _mint_token(str(user_id))
    headers = {"Authorization": f"Bearer {token}"}

    client = TestClient(app)
    response = client.patch(
        "/api/v1/profile/me", headers=headers, json={field: bad_url}
    )

    assert response.status_code == 422, response.text
    body = response.json()
    # FastAPI's default 422 body shape is {"detail": [{loc, msg, type}, ...]}.
    detail = body.get("detail")
    assert isinstance(detail, list) and detail
    # The offending field name must appear in at least one error's loc tuple.
    locs = [err.get("loc", []) for err in detail]
    assert any(field in [str(part) for part in loc] for loc in locs), body


# ---------------------------------------------------------------------------
# Property 19 — non-HTTPS provider base URL yields 422 on PUT /profile/settings.
# ---------------------------------------------------------------------------


_settings_non_https = st.one_of(
    st.sampled_from(
        [
            "http://api.openai.com/v1",
            "ftp://example.com",
            "://api.openai.com/v1",
            "not a url",
        ]
    ),
    st.text(min_size=1, max_size=32).filter(lambda s: not s.startswith("https://")),
)


@PROPERTY_SETTINGS
@given(bad_url=_settings_non_https)
def test_non_https_provider_base_url_returns_422(
    monkeypatch: pytest.MonkeyPatch, bad_url: str
) -> None:
    """Validates Requirement 6.7 / Property 19."""
    app, _state = _build_app(monkeypatch)
    user_id = uuid4()
    token = _mint_token(str(user_id))
    headers = {"Authorization": f"Bearer {token}"}

    client = TestClient(app)
    response = client.put(
        "/api/v1/profile/settings",
        headers=headers,
        json={
            "ai_key": "sk-test-1234abcd",
            "ai_provider_base_url": bad_url,
        },
    )

    assert response.status_code == 422, response.text
    body = response.json()
    detail = body.get("detail")
    assert isinstance(detail, list) and detail
    locs = [err.get("loc", []) for err in detail]
    assert any("ai_provider_base_url" in [str(part) for part in loc] for loc in locs), body
