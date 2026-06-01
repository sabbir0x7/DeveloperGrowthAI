"""``/api/v1/auth`` endpoints.

The authentication flow runs against Supabase from the Flutter client
directly (OTP issue/verify); the backend never holds session state. What
*this* router exposes is the single round-trip the frontend uses to confirm
a freshly-acquired access token is valid against the server-side JWT secret
before storing it locally.

Routes
------
* ``POST /verify-token`` — protected by ``Depends(get_current_user)``.
  Echoes the authenticated identity back as :class:`VerifyTokenResponse`.
  Any failure in the JWT dependency surfaces as HTTP 401 (Requirement 1.5);
  a successful call returns 200 with ``{id, email}`` (Requirement 1.4).
"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from app.core.security import CurrentUser
from app.middleware.jwt_auth import get_current_user
from app.schemas.auth import VerifyTokenResponse

# Mounted under ``/api/v1`` by main.py so the full path is
# ``/api/v1/auth/verify-token``.
router = APIRouter(prefix="/auth", tags=["auth"])


@router.post("/verify-token", response_model=VerifyTokenResponse)
def verify_token(user: CurrentUser = Depends(get_current_user)) -> VerifyTokenResponse:
    """Return the authenticated user record for a valid bearer token.

    The dependency does all the verification work; if we got here, the
    JWT was valid. We deliberately project only ``id`` and ``email`` (no
    raw claims) so the response surface stays tight regardless of what
    custom claims Supabase decides to include in future versions.
    """
    return VerifyTokenResponse(id=user.id, email=user.email)
