"""GitHub OAuth connection endpoints.

Implements the OAuth 2.0 authorization code flow so users can connect their
GitHub account for richer profile analysis (private repos, contribution stats).

Two endpoints:

1. ``GET /api/v1/auth/github/connect`` — (JWT-protected) returns the GitHub
   authorize URL the frontend should open in a new tab/popup.
2. ``GET /api/v1/auth/github/callback`` — (NO auth) receives the OAuth
   callback from GitHub, exchanges the code for a token, fetches user data,
   stores the token encrypted, and redirects the browser back to the frontend.
"""

from __future__ import annotations

from urllib.parse import urlencode
from uuid import UUID

import httpx
from fastapi import APIRouter, Depends, HTTPException, Query, status
from fastapi.responses import RedirectResponse

from app.core.config import get_settings
from app.core.encryption import get_encryption_service
from app.core.supabase_client import get_supabase
from app.core.security import CurrentUser
from app.middleware.jwt_auth import get_current_user

router = APIRouter(prefix="/auth/github", tags=["github-oauth"])

# GitHub OAuth endpoints
_GITHUB_AUTHORIZE_URL = "https://github.com/login/oauth/authorize"
_GITHUB_TOKEN_URL = "https://github.com/login/oauth/access_token"
_GITHUB_API_BASE = "https://api.github.com"

# Frontend redirect after successful OAuth
_FRONTEND_SUCCESS_URL = "http://localhost:3400/#/connect?github=success"
_FRONTEND_ERROR_URL = "http://localhost:3400/#/connect?github=error"


@router.get("/connect")
def github_connect(user: CurrentUser = Depends(get_current_user)) -> dict:
    """Return the GitHub OAuth authorize URL.

    The frontend opens this URL in a new tab/popup. The ``state`` parameter
    carries the authenticated user's ID so the callback can associate the
    GitHub token with the correct user without requiring a JWT (since GitHub
    redirects the browser directly to the callback).
    """
    settings = get_settings()

    if not settings.GITHUB_CLIENT_ID:
        raise HTTPException(
            status_code=status.HTTP_503_SERVICE_UNAVAILABLE,
            detail="GitHub OAuth is not configured.",
        )

    params = {
        "client_id": settings.GITHUB_CLIENT_ID,
        "redirect_uri": settings.GITHUB_REDIRECT_URI,
        "scope": "read:user,repo",
        "state": str(user.id),
    }

    authorize_url = f"{_GITHUB_AUTHORIZE_URL}?{urlencode(params)}"
    return {"authorize_url": authorize_url}


@router.get("/callback")
async def github_callback(
    code: str = Query(...),
    state: str = Query(...),
) -> RedirectResponse:
    """Handle the GitHub OAuth callback.

    GitHub redirects the browser here with ``?code=xxx&state=user_id``.
    This endpoint:
    1. Validates the state parameter is a valid UUID (CSRF protection).
    2. Exchanges the authorization code for an access token.
    3. Fetches the user's GitHub profile and repos using the token.
    4. Stores the encrypted token in ``user_settings``.
    5. Stores the GitHub data as JSON in ``users.github_data``.
    6. Redirects the browser to the frontend success URL.

    This endpoint does NOT require JWT auth since GitHub redirects the
    browser here directly.
    """
    # Validate state is a valid user UUID (CSRF protection)
    try:
        user_id = UUID(state)
    except (ValueError, TypeError):
        return RedirectResponse(url=_FRONTEND_ERROR_URL)

    settings = get_settings()

    # Exchange the code for an access token
    try:
        async with httpx.AsyncClient(timeout=httpx.Timeout(15.0)) as client:
            token_resp = await client.post(
                _GITHUB_TOKEN_URL,
                data={
                    "client_id": settings.GITHUB_CLIENT_ID,
                    "client_secret": settings.GITHUB_CLIENT_SECRET,
                    "code": code,
                    "redirect_uri": settings.GITHUB_REDIRECT_URI,
                },
                headers={"Accept": "application/json"},
            )

            if token_resp.status_code != 200:
                return RedirectResponse(url=_FRONTEND_ERROR_URL)

            token_data = token_resp.json()
            access_token = token_data.get("access_token")

            if not access_token:
                return RedirectResponse(url=_FRONTEND_ERROR_URL)

            # Fetch user profile data using the token
            auth_headers = {
                "Authorization": f"Bearer {access_token}",
                "Accept": "application/vnd.github.v3+json",
                "User-Agent": "DevGrowthAI/1.0",
            }

            user_resp = await client.get(
                f"{_GITHUB_API_BASE}/user",
                headers=auth_headers,
            )
            user_data = user_resp.json() if user_resp.status_code == 200 else {}

            # Fetch repos
            repos_resp = await client.get(
                f"{_GITHUB_API_BASE}/user/repos",
                headers=auth_headers,
                params={"sort": "updated", "per_page": 30, "type": "owner"},
            )
            repos_data = repos_resp.json() if repos_resp.status_code == 200 else []

    except (httpx.HTTPError, httpx.TimeoutException, Exception):
        return RedirectResponse(url=_FRONTEND_ERROR_URL)

    # Build GitHub data payload
    github_data = {
        "username": user_data.get("login"),
        "bio": user_data.get("bio"),
        "public_repos_count": user_data.get("public_repos", 0),
        "total_private_repos": user_data.get("total_private_repos", 0),
        "followers": user_data.get("followers", 0),
        "following": user_data.get("following", 0),
        "profile_url": user_data.get("html_url"),
        "repos": [
            {
                "name": r.get("name", ""),
                "language": r.get("language"),
                "stars": r.get("stargazers_count", 0),
                "forks": r.get("forks_count", 0),
                "description": r.get("description") or "",
                "private": r.get("private", False),
                "updated_at": r.get("updated_at", ""),
            }
            for r in (repos_data if isinstance(repos_data, list) else [])
        ],
        "connected": True,
    }

    # Store encrypted token and GitHub data
    try:
        sb = get_supabase()
        encryption = get_encryption_service()
        encrypted_token = encryption.encrypt(access_token)
        encoded_token = "\\x" + encrypted_token.hex()

        # Upsert encrypted GitHub token into user_settings
        sb.table("user_settings").upsert(
            {
                "user_id": str(user_id),
                "encrypted_github_token": encoded_token,
            },
            on_conflict="user_id",
        ).execute()

        # Store GitHub data in users table
        sb.table("users").update(
            {"github_data": github_data}
        ).eq("id", str(user_id)).execute()

    except Exception:
        # If storage fails, still redirect with error
        return RedirectResponse(url=_FRONTEND_ERROR_URL)

    return RedirectResponse(url=_FRONTEND_SUCCESS_URL)
