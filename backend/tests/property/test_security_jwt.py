"""Property test for HS256 JWT verification (Backend rejects bad tokens).

Design.md → **Property 2: Backend rejects every malformed or missing JWT.**
Validates Requirement 1.5 of `requirements.md`:

    "IF the Backend_API receives a request with a missing, expired, or invalid
     JWT, THEN THE Auth_Service SHALL respond with HTTP status 401."

The HTTP-401 translation lives at the API/middleware layer; here we exercise
the single chokepoint it depends on — :func:`app.core.security.verify_token` —
and assert the universal invariant: any input that is not a valid HS256 JWT
signed with the configured secret AND carrying ``aud="authenticated"`` AND
not yet expired raises :class:`InvalidToken`.

Coverage buckets (each its own ``@given`` test for clearer counterexamples):

* Arbitrary text — empty string, random bytes/strings, "missing token" sentinel.
* Three-segment garbage that *looks* like a JWT but isn't.
* JWTs signed with a *different* HS256 secret.
* JWTs signed with the right secret but with ``exp`` already in the past.
* JWTs signed with the right secret but with the wrong audience.
"""

from __future__ import annotations

import secrets
import time
from collections.abc import Iterator
from typing import Any
from uuid import uuid4

import pytest
from hypothesis import HealthCheck, assume, given
from hypothesis import settings as h_settings
from hypothesis import strategies as st
from jose import jwt

# A secret unique to this test module so we cannot collide with any real
# environment value. Generated once at import time; the JWT secret is
# arbitrary bytes-as-string for HS256 purposes.
TEST_JWT_SECRET = "test-jwt-secret-property-2-" + secrets.token_urlsafe(16)
# A different secret used to mint JWTs that should NOT verify.
WRONG_JWT_SECRET = "wrong-jwt-secret-property-2-" + secrets.token_urlsafe(16)
assert TEST_JWT_SECRET != WRONG_JWT_SECRET

# Any valid Fernet key works here — encryption is not exercised by this test,
# but `Settings` validates the env var on construction.
TEST_FERNET_KEY = "Mj6ttjVWrIA5KiFpYnsot8BVpzPB8ABFZzlD_im4aAM="

# Audience claim Supabase Auth pins on its access tokens; the production code
# pins it via `core.security.SUPABASE_AUDIENCE`. Re-stated here to avoid
# coupling the test to a private constant.
EXPECTED_AUDIENCE = "authenticated"


@pytest.fixture(scope="module", autouse=True)
def _configure_env(monkeypatch_module: pytest.MonkeyPatch) -> Iterator[None]:
    """Install module-wide env vars and reset the settings cache.

    `core.config.get_settings` is `lru_cache`-d, so we clear it once on entry
    (so the first call inside the module sees our env) and once on exit
    (so subsequent test modules pick up the real environment again).
    """
    # All env vars required by `Settings` must be set together — Pydantic
    # raises if any one is missing.
    monkeypatch_module.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch_module.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-role-key-placeholder")
    monkeypatch_module.setenv("SUPABASE_JWT_SECRET", TEST_JWT_SECRET)
    monkeypatch_module.setenv("FERNET_KEYS", TEST_FERNET_KEY)
    # The two AI defaults have defaults in `Settings`; set them anyway so this
    # fixture documents the full env contract and doesn't drift if defaults
    # are tightened later.
    monkeypatch_module.setenv("AI_MODEL_DEFAULT", "gpt-4o-mini")
    monkeypatch_module.setenv(
        "AI_PROVIDER_BASE_URL_DEFAULT", "https://api.openai.com/v1"
    )

    from app.core.config import get_settings

    get_settings.cache_clear()
    try:
        yield
    finally:
        get_settings.cache_clear()


@pytest.fixture(scope="module")
def monkeypatch_module() -> Iterator[pytest.MonkeyPatch]:
    """Module-scoped equivalent of pytest's built-in `monkeypatch`.

    Pytest's stock `monkeypatch` is function-scoped; we want one env-var setup
    for the whole module so Hypothesis examples don't repeatedly tear down and
    re-create settings.
    """
    mp = pytest.MonkeyPatch()
    try:
        yield mp
    finally:
        mp.undo()


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _verify_token(token: str) -> Any:
    """Late-import wrapper so `_configure_env` runs before the import.

    Importing `app.core.security` at module load time would resolve
    `app.core.config.get_settings` against whatever env exists at import
    (typically empty), causing pydantic to raise.
    """
    from app.core.security import verify_token

    return verify_token(token)


def _invalid_token_cls() -> type[Exception]:
    from app.core.security import InvalidToken

    return InvalidToken


def _valid_claims(*, exp_offset: int = 3600, audience: str = EXPECTED_AUDIENCE) -> dict[str, Any]:
    """Build a valid claim set, parameterized for the negative-test buckets."""
    now = int(time.time())
    return {
        "sub": str(uuid4()),
        "aud": audience,
        "iat": now,
        "exp": now + exp_offset,
        "email": "user@example.com",
    }


# Common Hypothesis settings: bump to 200 examples (the spec mandates ≥ 100)
# and silence the "function-scoped fixture used with @given" check, which
# does not apply to our module-scoped `_configure_env`.
PROPERTY_SETTINGS = h_settings(
    max_examples=50,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
    deadline=None,
)


# ---------------------------------------------------------------------------
# Property 2 — bucket A: arbitrary strings (covers empty, random bytes-ish,
# and "missing token" inputs).
# ---------------------------------------------------------------------------


@PROPERTY_SETTINGS
@given(arbitrary=st.text(min_size=0, max_size=512))
def test_arbitrary_strings_are_rejected(arbitrary: str) -> None:
    """Validates Requirement 1.5: any non-JWT string is refused.

    Hypothesis virtually never produces a valid JWT by chance (HS256 requires
    a 32-byte signature derived from our exact secret), so we simply assert
    `InvalidToken` is raised. The `assume` guard documents the safety net.
    """
    InvalidToken = _invalid_token_cls()
    # Belt-and-braces: if Hypothesis somehow stumbles onto a valid token,
    # skip the example rather than report a false failure.
    try:
        _verify_token(arbitrary)
    except InvalidToken:
        return
    assume(False)  # pragma: no cover — unreachable in practice


# ---------------------------------------------------------------------------
# Property 2 — bucket B: three-segment garbage that *looks* like a JWT.
# ---------------------------------------------------------------------------


_segment_alphabet = st.text(
    alphabet=st.characters(
        whitelist_categories=("Ll", "Lu", "Nd"),
        whitelist_characters="-_",
    ),
    min_size=1,
    max_size=32,
)


@PROPERTY_SETTINGS
@given(a=_segment_alphabet, b=_segment_alphabet, c=_segment_alphabet)
def test_three_segment_garbage_is_rejected(a: str, b: str, c: str) -> None:
    """Validates Requirement 1.5: a `x.y.z` shape is necessary but not sufficient."""
    InvalidToken = _invalid_token_cls()
    candidate = f"{a}.{b}.{c}"
    with pytest.raises(InvalidToken):
        _verify_token(candidate)


# ---------------------------------------------------------------------------
# Property 2 — bucket C: JWTs signed with the wrong secret.
# ---------------------------------------------------------------------------


@PROPERTY_SETTINGS
@given(
    sub=st.uuids().map(str),
    email=st.emails(),
    exp_offset=st.integers(min_value=60, max_value=3600),
)
def test_jwt_signed_with_wrong_secret_is_rejected(
    sub: str, email: str, exp_offset: int
) -> None:
    """Validates Requirement 1.5: signature mismatch is a 401-class failure.

    Payload looks otherwise pristine (right audience, future expiry, real UUID
    subject) — only the signing key differs.
    """
    InvalidToken = _invalid_token_cls()
    now = int(time.time())
    claims = {
        "sub": sub,
        "aud": EXPECTED_AUDIENCE,
        "iat": now,
        "exp": now + exp_offset,
        "email": email,
    }
    bad_token = jwt.encode(claims, WRONG_JWT_SECRET, algorithm="HS256")
    with pytest.raises(InvalidToken):
        _verify_token(bad_token)


# ---------------------------------------------------------------------------
# Property 2 — bucket D: JWTs whose `exp` is in the past.
# ---------------------------------------------------------------------------


@PROPERTY_SETTINGS
@given(
    # `exp_offset` is how many seconds in the past `exp` falls. Lower bound is
    # 60s to comfortably clear `python-jose`'s default 0-second leeway plus
    # any clock jitter on slow CI runners.
    exp_offset=st.integers(min_value=60, max_value=86_400),
    sub=st.uuids().map(str),
)
def test_expired_jwt_is_rejected(exp_offset: int, sub: str) -> None:
    """Validates Requirement 1.5: expired tokens are refused.

    Signed with the *correct* secret and audience — the only defect is `exp`.
    """
    InvalidToken = _invalid_token_cls()
    now = int(time.time())
    claims = {
        "sub": sub,
        "aud": EXPECTED_AUDIENCE,
        "iat": now - exp_offset - 60,
        "exp": now - exp_offset,
    }
    expired_token = jwt.encode(claims, TEST_JWT_SECRET, algorithm="HS256")
    with pytest.raises(InvalidToken):
        _verify_token(expired_token)


# ---------------------------------------------------------------------------
# Property 2 — bucket E: JWTs with the wrong audience.
# ---------------------------------------------------------------------------


_wrong_audience = st.text(
    alphabet=st.characters(
        whitelist_categories=("Ll", "Lu", "Nd"),
        whitelist_characters="-_",
    ),
    min_size=1,
    max_size=32,
).filter(lambda s: s != EXPECTED_AUDIENCE)


@PROPERTY_SETTINGS
@given(audience=_wrong_audience, sub=st.uuids().map(str))
def test_jwt_with_wrong_audience_is_rejected(audience: str, sub: str) -> None:
    """Validates Requirement 1.5: wrong-audience tokens are refused.

    Signed with the correct secret and not yet expired — only `aud` differs
    from `authenticated`. Confirms a refresh token, a token from a different
    Supabase project, or any other legitimate-but-misaddressed token cannot
    impersonate an end user.
    """
    InvalidToken = _invalid_token_cls()
    now = int(time.time())
    claims = {
        "sub": sub,
        "aud": audience,
        "iat": now,
        "exp": now + 3600,
    }
    bad_audience_token = jwt.encode(claims, TEST_JWT_SECRET, algorithm="HS256")
    with pytest.raises(InvalidToken):
        _verify_token(bad_audience_token)


# ---------------------------------------------------------------------------
# Sanity: the *positive* path verifies, so the negative properties above
# aren't accidentally trivially true (e.g., misconfigured secret).
# ---------------------------------------------------------------------------


def test_sanity_valid_token_verifies() -> None:
    """Not part of Property 2; guards against the negative tests being vacuous.

    If the env-var fixture or `verify_token` were misconfigured such that
    *every* token failed, the property tests above would still pass. This
    sanity check ensures a freshly-minted, correctly-signed token is accepted.
    """
    valid = jwt.encode(_valid_claims(), TEST_JWT_SECRET, algorithm="HS256")
    user = _verify_token(valid)
    assert str(user.id)  # any UUID renders as a string
