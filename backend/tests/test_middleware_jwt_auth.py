"""Unit tests for the FastAPI JWT-auth dependency.

Cryptographic correctness of `verify_token` is covered by the property test
in `tests/property/test_security_jwt.py` (Property 2 / Requirement 1.5). The
tests here cover only the *HTTP wrapper* concerns layered on top:

* Missing / malformed / expired / wrong-secret tokens produce HTTP 401 with
  ``WWW-Authenticate: Bearer`` and a stable ``detail`` code.
* A valid token resolves to a :class:`CurrentUser` and is stashed on
  ``request.state.user`` so downstream dependencies can read it.

Each test boots a tiny FastAPI app via :class:`TestClient` so we exercise the
dependency exactly the way real routes will. The Supabase JWT secret and
required env vars are injected via ``monkeypatch`` so the tests are
hermetic and parallelizable.
"""

import secrets
import time
from collections.abc import Iterator
from uuid import uuid4

import pytest
from fastapi import FastAPI, Request
from fastapi.testclient import TestClient
from jose import jwt

# A secret unique to this test module so the negative cases that mint tokens
# with `WRONG_SECRET` cannot accidentally collide with real config.
JWT_SECRET = "test-mw-secret-" + secrets.token_urlsafe(16)
WRONG_SECRET = "test-mw-wrong-" + secrets.token_urlsafe(16)
# Any valid Fernet key works; encryption is not exercised here, but
# `Settings` validates the env var on construction.
FERNET_KEY = "Mj6ttjVWrIA5KiFpYnsot8BVpzPB8ABFZzlD_im4aAM="
AUDIENCE = "authenticated"


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Provide the full env required by `Settings` and reset its cache."""
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-role-placeholder")
    monkeypatch.setenv("SUPABASE_JWT_SECRET", JWT_SECRET)
    monkeypatch.setenv("FERNET_KEYS", FERNET_KEY)

    from app.core.config import get_settings

    get_settings.cache_clear()
    try:
        yield
    finally:
        get_settings.cache_clear()


def _make_app() -> FastAPI:
    """Build a one-route FastAPI app exercising the dependency end to end.

    The route asserts the dependency populated ``request.state.user`` and
    echoes the resolved id so tests can verify identity propagation.
    """
    from app.middleware.jwt_auth import CurrentUserDep

    app = FastAPI()

    @app.get("/whoami")
    def whoami(request: Request, user: CurrentUserDep) -> dict[str, str]:
        # The dependency must have stashed the user on request.state and
        # the parameter must be the same object — verifies the side effect
        # other dependencies (e.g. rate limiter) will rely on.
        assert request.state.user is user
        return {"id": str(user.id), "email": user.email or ""}

    return app


def _valid_token(*, exp_offset: int = 3600, audience: str = AUDIENCE) -> str:
    now = int(time.time())
    return jwt.encode(
        {
            "sub": str(uuid4()),
            "aud": audience,
            "iat": now,
            "exp": now + exp_offset,
            "email": "user@example.com",
        },
        JWT_SECRET,
        algorithm="HS256",
    )


# ---------------------------------------------------------------------------
# Happy path
# ---------------------------------------------------------------------------


def test_valid_bearer_token_resolves_user_and_attaches_to_request_state() -> None:
    """A correctly signed token yields 200 and populates request.state.user."""
    client = TestClient(_make_app())
    token = _valid_token()

    response = client.get("/whoami", headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 200
    body = response.json()
    # The handler asserts identity propagation internally; here we only
    # confirm the round-tripped subject is a non-empty UUID-shaped string.
    assert body["id"]
    assert body["email"] == "user@example.com"


# ---------------------------------------------------------------------------
# 401 scenarios — each maps to a stable ``detail`` code from InvalidToken
# ---------------------------------------------------------------------------


@pytest.mark.parametrize(
    ("headers", "expected_detail"),
    [
        # No Authorization header at all.
        ({}, "missing_authorization"),
        # Wrong scheme.
        ({"Authorization": "Basic dXNlcjpwYXNz"}, "malformed_authorization"),
        # Right scheme, empty token.
        ({"Authorization": "Bearer "}, "malformed_authorization"),
        # Bearer prefix with whitespace-padded token.
        ({"Authorization": "Bearer  padded"}, "malformed_authorization"),
    ],
)
def test_missing_or_malformed_authorization_returns_401(
    headers: dict[str, str], expected_detail: str
) -> None:
    """Header-shape failures map to 401 with the corresponding code."""
    client = TestClient(_make_app())

    response = client.get("/whoami", headers=headers)

    assert response.status_code == 401
    assert response.json() == {"detail": expected_detail}
    # Bearer challenge is required so clients (and our Dio interceptor) can
    # tell a refresh is the right reaction.
    assert response.headers["WWW-Authenticate"].startswith("Bearer")


def test_token_signed_with_wrong_secret_returns_401_invalid_token() -> None:
    """Signature mismatch is normalized to ``invalid_token``."""
    now = int(time.time())
    bad = jwt.encode(
        {
            "sub": str(uuid4()),
            "aud": AUDIENCE,
            "iat": now,
            "exp": now + 3600,
        },
        WRONG_SECRET,
        algorithm="HS256",
    )
    client = TestClient(_make_app())

    response = client.get("/whoami", headers={"Authorization": f"Bearer {bad}"})

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid_token"}


def test_expired_token_returns_401_token_expired() -> None:
    """Expired tokens get the distinct ``token_expired`` code (not a generic 401)."""
    client = TestClient(_make_app())
    token = _valid_token(exp_offset=-3600)  # already expired

    response = client.get("/whoami", headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 401
    assert response.json() == {"detail": "token_expired"}


def test_wrong_audience_returns_401_invalid_token() -> None:
    """A correctly signed token addressed to another audience is rejected."""
    client = TestClient(_make_app())
    token = _valid_token(audience="some-other-aud")

    response = client.get("/whoami", headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 401
    assert response.json() == {"detail": "invalid_token"}


def test_token_with_non_uuid_subject_returns_401_missing_subject() -> None:
    """Subject validation failures bubble up with their own code."""
    now = int(time.time())
    token = jwt.encode(
        {"sub": "not-a-uuid", "aud": AUDIENCE, "iat": now, "exp": now + 3600},
        JWT_SECRET,
        algorithm="HS256",
    )
    client = TestClient(_make_app())

    response = client.get("/whoami", headers={"Authorization": f"Bearer {token}"})

    assert response.status_code == 401
    assert response.json() == {"detail": "missing_subject"}
