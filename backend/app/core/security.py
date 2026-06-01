"""JWT verification for Supabase-issued access tokens (HS256 + ES256).

Supabase Auth signs access tokens with either HS256 (older/self-hosted
projects) or ES256 (newer cloud projects). This module is the single
chokepoint for verification: routes never call ``jwt.decode`` directly,
they go through :func:`verify_token` (and :func:`parse_bearer` for
header parsing).

Failure modes are normalized to a single :class:`InvalidToken` exception so
the API layer has one thing to catch and translate to HTTP 401.
"""

from __future__ import annotations

import json
from dataclasses import dataclass, field
from functools import lru_cache
from typing import Any
from uuid import UUID

import httpx
from jose import ExpiredSignatureError, JWTError, jwt
from jose.utils import base64url_decode

from app.core.config import get_settings

# Supabase issues access tokens with this audience claim. We pin it so a token
# minted for a different audience (e.g. a refresh token, a service token from
# another project) cannot impersonate an authenticated end user.
SUPABASE_AUDIENCE = "authenticated"


class InvalidToken(Exception):
    """Raised whenever a JWT cannot be trusted.

    The ``detail`` string is a stable, machine-readable code (e.g.
    ``"token_expired"``, ``"invalid_token"``, ``"missing_subject"``) that the
    API layer surfaces as the body of an HTTP 401 response. It is intentionally
    coarse: callers should not branch on the *reason* a token is bad, only
    that it is.
    """

    def __init__(self, detail: str = "invalid_token") -> None:
        super().__init__(detail)
        self.detail = detail


@dataclass(frozen=True)
class CurrentUser:
    """Authenticated identity derived from a verified Supabase JWT.

    Frozen because every consumer treats it as a value: it gets attached to
    ``request.state`` and read from there, never mutated. ``claims`` is the
    raw decoded payload kept for downstream needs (e.g. inspecting custom
    Supabase claims) without forcing each caller to re-decode the token.
    """

    id: UUID
    email: str | None
    claims: dict[str, Any] = field(default_factory=dict)


@lru_cache(maxsize=1)
def _fetch_jwks() -> dict[str, Any] | None:
    """Fetch the JWKS from the Supabase project's well-known endpoint.

    Returns the first key in the keyset, or None if fetching fails.
    Cached for the lifetime of the process (keys rarely rotate).
    """
    settings = get_settings()
    url = str(settings.SUPABASE_URL).rstrip("/") + "/auth/v1/.well-known/jwks.json"
    try:
        response = httpx.get(url, timeout=10.0)
        if response.status_code == 200:
            data = response.json()
            keys = data.get("keys", [])
            if keys:
                return keys[0]
    except Exception:
        pass
    return None


def _get_algorithm_from_token(token: str) -> str:
    """Read the `alg` field from the JWT header without verifying."""
    try:
        header_segment = token.split(".")[0]
        # Add padding
        padding = 4 - len(header_segment) % 4
        if padding != 4:
            header_segment += "=" * padding
        header_bytes = base64url_decode(header_segment.encode("utf-8"))
        header = json.loads(header_bytes)
        return header.get("alg", "HS256")
    except Exception:
        return "HS256"


def verify_token(token: str) -> CurrentUser:
    """Decode and verify a Supabase JWT, returning the caller's identity.

    Supports both HS256 (symmetric, using SUPABASE_JWT_SECRET) and ES256
    (asymmetric, using JWKS fetched from the Supabase project URL).

    Verifies signature, expiration, and audience. Any failure - bad
    signature, expired token, wrong audience, missing or non-UUID ``sub``
    claim - is raised as :class:`InvalidToken` with a stable detail code.
    """
    settings = get_settings()
    alg = _get_algorithm_from_token(token)

    try:
        if alg == "ES256":
            # Asymmetric verification using JWKS
            jwk = _fetch_jwks()
            if jwk is None:
                raise InvalidToken("invalid_token")
            claims = jwt.decode(
                token,
                jwk,
                algorithms=["ES256"],
                audience=SUPABASE_AUDIENCE,
                options={
                    "verify_aud": True,
                    "verify_exp": True,
                    "verify_signature": True,
                },
            )
        else:
            # Symmetric HS256 verification using the shared secret
            claims = jwt.decode(
                token,
                settings.SUPABASE_JWT_SECRET,
                algorithms=["HS256"],
                audience=SUPABASE_AUDIENCE,
                options={
                    "verify_aud": True,
                    "verify_exp": True,
                    "verify_signature": True,
                },
            )
    except ExpiredSignatureError as exc:
        raise InvalidToken("token_expired") from exc
    except JWTError as exc:
        raise InvalidToken("invalid_token") from exc

    sub = claims.get("sub")
    if not isinstance(sub, str) or not sub:
        raise InvalidToken("missing_subject")
    try:
        user_id = UUID(sub)
    except (ValueError, AttributeError, TypeError) as exc:
        raise InvalidToken("missing_subject") from exc

    email = claims.get("email")
    if email is not None and not isinstance(email, str):
        email = None

    return CurrentUser(id=user_id, email=email, claims=claims)


def parse_bearer(authorization_header: str | None) -> str:
    """Extract the raw JWT from an ``Authorization: Bearer <token>`` header.

    Accepts only the exact ``"Bearer "`` prefix (case-sensitive, single space)
    followed by a non-empty token. Anything else - missing header, wrong
    scheme, missing token, extra whitespace - raises :class:`InvalidToken`
    with a code that distinguishes "no header" from "malformed header" so
    operators can tell client bugs from anonymous traffic in logs.
    """
    if authorization_header is None:
        raise InvalidToken("missing_authorization")

    prefix = "Bearer "
    if not authorization_header.startswith(prefix):
        raise InvalidToken("malformed_authorization")

    token = authorization_header[len(prefix):]
    if not token or token != token.strip():
        raise InvalidToken("malformed_authorization")

    return token
