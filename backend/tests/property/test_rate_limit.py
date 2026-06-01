"""Property tests for the per-user analysis rate limiter.

Validates three universal invariants of `app.middleware.rate_limit`:

* **Property 20** — Sliding-window cap admits at most 10 requests per user
  per 60-second window on `/api/v1/analysis/*`. Validates Requirement 7.1.
* **Property 21** — The 11th-or-later request from the same user inside the
  same window returns HTTP 429 with a non-negative integer ``Retry-After``
  header. Validates Requirement 7.2.
* **Property 22** — Unauthenticated requests on the same path always return
  HTTP 401 (from the JWT dependency) and never 429, regardless of how many
  arrive. Validates Requirement 7.3.

Every test uses a unique authenticated subject (a fresh UUID per Hypothesis
example) so the in-memory sliding-window storage never accumulates cross-test
state. Where a single example issues many requests for the *same* user, the
test still fits well inside one 60-second window so the sliding-window math
is meaningful and not affected by clock drift.
"""

# NOTE: deliberately no ``from __future__ import annotations`` here. FastAPI
# resolves the runtime annotations on the route handler at decorator time,
# and our handler annotates ``user`` with ``CurrentUser``. Stringified
# annotations would force FastAPI to look up ``CurrentUser`` in the module's
# globals, where it isn't imported, and break the test app construction.

import secrets
import time
from collections.abc import Iterator
from uuid import uuid4

import pytest
from fastapi import Depends, FastAPI, Request, Response
from fastapi.testclient import TestClient
from hypothesis import HealthCheck, given, settings as h_settings, strategies as st
from jose import jwt

# Hermetic env: every Settings field is provided locally so this module never
# touches real credentials. The JWT secret is unique per import so two
# concurrent test runs cannot accidentally accept each other's tokens.
JWT_SECRET = "test-rl-secret-" + secrets.token_urlsafe(16)
FERNET_KEY = "Mj6ttjVWrIA5KiFpYnsot8BVpzPB8ABFZzlD_im4aAM="
AUDIENCE = "authenticated"

# The rate limit string the production module uses. Keeping a literal here
# (rather than importing the constant) doubles as a regression check: if
# someone changes the limit, both this file and the property numbers must be
# revisited together.
EXPECTED_LIMIT = 10

PROPERTY_SETTINGS = h_settings(
    max_examples=25,  # bounded to keep total HTTP request count reasonable
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

    from app.core.config import get_settings

    get_settings.cache_clear()
    try:
        yield
    finally:
        get_settings.cache_clear()


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


def _make_app() -> FastAPI:
    """Build a minimal FastAPI app shaped like the analysis router.

    The route mirrors the production wiring exactly:

    * ``Depends(get_current_user)`` so the JWT dependency runs *before* the
      limiter and unauthenticated requests get 401 (Requirement 7.3 /
      Property 22).
    * The limiter is applied via ``fresh.limit`` so the slowapi limiter
      runs (Requirements 7.1 / 7.2, Properties 20 / 21).
    * ``request: Request`` and ``response: Response`` parameters because
      slowapi needs both to read the key and write the X-RateLimit-* headers.

    A fresh app and a fresh limiter storage are created per call so each
    test starts with empty counters - mandatory because slowapi keeps its
    sliding-window state in process memory keyed by user id.
    """
    from slowapi import Limiter
    from slowapi.errors import RateLimitExceeded

    from app.core.security import CurrentUser
    from app.middleware import rate_limit as rate_limit_module
    from app.middleware.jwt_auth import get_current_user
    from app.middleware.rate_limit import (
        ANALYSIS_RATE_LIMIT,
        rate_limit_exceeded_handler,
    )

    # Replace the module-level limiter with a fresh one so any state that
    # leaked from earlier examples is gone.
    fresh = Limiter(
        key_func=rate_limit_module._user_id_key,
        default_limits=[],
        strategy="moving-window",
        headers_enabled=True,
        auto_check=True,
    )
    rate_limit_module.limiter = fresh

    app = FastAPI()
    app.state.limiter = fresh
    app.add_exception_handler(RateLimitExceeded, rate_limit_exceeded_handler)

    @app.post("/api/v1/analysis/run")
    @fresh.limit(ANALYSIS_RATE_LIMIT)
    async def run_analysis(
        request: Request,
        response: Response,
        user: CurrentUser = Depends(get_current_user),
    ):
        # Echo the user id so callers can confirm the dependency resolved.
        return {"id": str(user.id)}

    return app


# ---------------------------------------------------------------------------
# Property 20 — sliding-window cap admits at most 10 requests per window.
# ---------------------------------------------------------------------------


@PROPERTY_SETTINGS
@given(burst_size=st.integers(min_value=1, max_value=20))
def test_at_most_10_requests_per_minute_admitted(burst_size: int) -> None:
    """Validates Requirement 7.1: per-user sliding-window cap of 10/minute.

    Issues `burst_size` back-to-back requests as the same authenticated
    user (a fresh UUID each example so sliding-window state is isolated)
    and asserts the count of admitted (non-429) responses is at most 10.
    """
    client = TestClient(_make_app())
    token = _mint_token()
    admitted = 0
    for _ in range(burst_size):
        resp = client.post(
            "/api/v1/analysis/run",
            headers={"Authorization": f"Bearer {token}"},
        )
        if resp.status_code != 429:
            admitted += 1
    assert admitted <= EXPECTED_LIMIT


# ---------------------------------------------------------------------------
# Property 21 — over-limit requests return 429 + non-negative Retry-After.
# ---------------------------------------------------------------------------


@PROPERTY_SETTINGS
@given(extras=st.integers(min_value=1, max_value=5))
def test_eleventh_request_returns_429_with_retry_after(extras: int) -> None:
    """Validates Requirement 7.2: 11th+ request returns 429 with non-negative integer Retry-After."""
    client = TestClient(_make_app())
    token = _mint_token()

    # Saturate the budget; every one of these should be admitted.
    for _ in range(EXPECTED_LIMIT):
        ok = client.post(
            "/api/v1/analysis/run",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert ok.status_code == 200

    # Every additional request inside the same window must be rejected.
    for _ in range(extras):
        resp = client.post(
            "/api/v1/analysis/run",
            headers={"Authorization": f"Bearer {token}"},
        )
        assert resp.status_code == 429, resp.text
        retry_after_header = resp.headers.get("Retry-After")
        assert retry_after_header is not None
        retry_after = int(retry_after_header)
        assert retry_after >= 0


# ---------------------------------------------------------------------------
# Property 22 — unauthenticated traffic is always 401, never 429.
# ---------------------------------------------------------------------------


@PROPERTY_SETTINGS
@given(burst_size=st.integers(min_value=1, max_value=20))
def test_unauthenticated_requests_always_401_never_429(burst_size: int) -> None:
    """Validates Requirement 7.3: JWT dependency runs before the limiter."""
    client = TestClient(_make_app())
    for _ in range(burst_size):
        resp = client.post("/api/v1/analysis/run")  # no Authorization header
        assert resp.status_code == 401
        assert resp.status_code != 429
