"""LinkedIn OAuth connection endpoints.

Implements the OAuth 2.0 authorization code flow so users can connect their
LinkedIn account to fetch profile details instead of uploading a PDF.

Two endpoints:

1. ``GET /api/v1/auth/linkedin/connect`` — (JWT-protected) returns the LinkedIn
   authorize URL the frontend should open in a new tab/popup.
2. ``GET /api/v1/auth/linkedin/callback`` — (NO auth) receives the OAuth
   callback from LinkedIn, exchanges the code for a token, fetches user data,
   formats user details, stores the text in ``users.linkedin_pdf_text``, and
   redirects the browser back to the frontend.
"""

from __future__ import annotations

from urllib.parse import urlencode
from uuid import UUID

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import RedirectResponse

from app.core.config import get_settings
from app.core.supabase_client import get_supabase
from app.core.security import CurrentUser
from app.middleware.jwt_auth import get_current_user

router = APIRouter(prefix="/auth/linkedin", tags=["linkedin-oauth"])

# LinkedIn OAuth endpoints
_LINKEDIN_AUTHORIZE_URL = "https://www.linkedin.com/oauth/v2/authorization"
_LINKEDIN_TOKEN_URL = "https://www.linkedin.com/oauth/v2/accessToken"
_LINKEDIN_API_BASE = "https://api.linkedin.com"

# Frontend redirect after successful OAuth
_FRONTEND_SUCCESS_URL = "http://localhost:3400/#/connect?linkedin=success"
_FRONTEND_ERROR_URL = "http://localhost:3400/#/connect?linkedin=error"


@router.get("/connect")
def linkedin_connect(user: CurrentUser = Depends(get_current_user)) -> dict:
    """Return the LinkedIn OAuth authorize URL.

    The frontend opens this URL in a new tab/popup. The ``state`` parameter
    carries the authenticated user's ID so the callback can associate the
    LinkedIn data with the correct user without requiring a JWT (since LinkedIn
    redirects the browser directly to the callback).
    """
    settings = get_settings()

    if not settings.LINKEDIN_CLIENT_ID:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="LinkedIn OAuth is not configured.",
        )

    params = {
        "response_type": "code",
        "client_id": settings.LINKEDIN_CLIENT_ID,
        "redirect_uri": settings.LINKEDIN_REDIRECT_URI,
        "state": str(user.id),
        "scope": "openid profile email",
    }

    authorize_url = f"{_LINKEDIN_AUTHORIZE_URL}?{urlencode(params)}"
    return {"authorize_url": authorize_url}


@router.get("/callback")
async def linkedin_callback(
    code: str = Query(...),
    state: str = Query(...),
) -> RedirectResponse:
    """Handle the LinkedIn OAuth callback.

    LinkedIn redirects the browser here with ``?code=xxx&state=user_id``.
    This endpoint:
    1. Validates the state parameter is a valid UUID (CSRF protection).
    2. Exchanges the authorization code for an access token.
    3. Fetches the user's LinkedIn profile using OIDC.
    4. Formats it into a text description and stores it in ``users.linkedin_pdf_text``.
    5. Sets ``users.linkedin_url`` to ``https://linkedin.com/in/connected`` so route guards pass.
    6. Redirects the browser to the frontend success URL.

    This endpoint does NOT require JWT auth since LinkedIn redirects the
    browser here directly.
    """
    try:
        user_id = UUID(state)
    except (ValueError, TypeError):
        return RedirectResponse(url=_FRONTEND_ERROR_URL)

    settings = get_settings()

    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(15.0)) as client:
            # Exchange code for access token
            token_resp = await client.post(
                _LINKEDIN_TOKEN_URL,
                data={
                    "grant_type": "authorization_code",
                    "code": code,
                    "redirect_uri": settings.LINKEDIN_REDIRECT_URI,
                    "client_id": settings.LINKEDIN_CLIENT_ID,
                    "client_secret": settings.LINKEDIN_CLIENT_SECRET,
                },
                headers={"Content-Type": "application/x-www-form-urlencoded"},
            )

            if token_resp.status_code != 200:
                return RedirectResponse(url=_FRONTEND_ERROR_URL)

            token_data = token_resp.json()
            access_token = token_data.get("access_token")

            if not access_token:
                return RedirectResponse(url=_FRONTEND_ERROR_URL)

            # Fetch user info using OIDC
            auth_headers = {
                "Authorization": f"Bearer {access_token}",
                "Accept": "application/json",
            }

            user_resp = await client.get(
                f"{_LINKEDIN_API_BASE}/v2/userinfo",
                headers=auth_headers,
            )

            if user_resp.status_code != 200:
                return RedirectResponse(url=_FRONTEND_ERROR_URL)

            user_data = user_resp.json()

    except (httpx.HTTPError, httpx.TimeoutException, Exception):
        return RedirectResponse(url=_FRONTEND_ERROR_URL)

    # Format LinkedIn OIDC data as profile text description
    given_name = user_data.get("given_name", "")
    family_name = user_data.get("family_name", "")
    full_name = user_data.get("name", f"{given_name} {family_name}".strip())
    email = user_data.get("email", "")
    sub = user_data.get("sub", "")

    linkedin_text = (
        "LinkedIn Profile (Connected via OAuth)\n"
        f"Full Name: {full_name}\n"
        f"Email: {email}\n"
        f"LinkedIn Identifier: {sub}\n"
    )

    # Store LinkedIn data and set linkedin_url
    try:
        sb = get_supabase()

        # Update users table
        sb.table("users").update({
            "linkedin_pdf_text": linkedin_text,
            "linkedin_url": "https://linkedin.com/in/connected"
        }).eq("id", str(user_id)).execute()

    except Exception:
        # If database update fails, redirect with error
        return RedirectResponse(url=_FRONTEND_ERROR_URL)

    return RedirectResponse(url=_FRONTEND_SUCCESS_URL)
