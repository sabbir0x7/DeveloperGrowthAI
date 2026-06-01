"""GitHub profile scraping service.

Fetches public profile data from the GitHub REST API (unauthenticated)
to enrich the AI analysis prompt with real repository and language data
instead of relying solely on the LLM to interpret a bare URL.

Rate limits: 60 requests/hour per IP without authentication. Acceptable
for the current user base; a future iteration can add a GitHub token via
settings if needed.

Design:
* Uses ``httpx.AsyncClient`` with a 15-second timeout.
* Extracts the username from a GitHub URL (e.g. ``https://github.com/sabbir0x7``).
* Fetches user metadata and up to 30 most-recently-updated repos.
* Aggregates top languages across repos.
* Returns a structured dict ready for prompt injection.
* On any failure (404, timeout, network error), returns a minimal fallback
  dict containing only the original URL so the AI can still attempt analysis.
"""

from __future__ import annotations

import re
from collections import Counter
from typing import Any
from urllib.parse import urlparse

import httpx

# Timeout for all GitHub API calls (connect + read).
_TIMEOUT = httpx.Timeout(15.0)

# GitHub API base.
_API_BASE = "https://api.github.com"

# User-Agent header required by GitHub API.
_HEADERS = {
    "Accept": "application/vnd.github.v3+json",
    "User-Agent": "DevGrowthAI/1.0",
}

# Max repos to fetch (GitHub default page size cap is 100).
_MAX_REPOS = 30

# Max repos to include in the prompt summary (keep token usage reasonable).
_TOP_REPOS_IN_PROMPT = 10


def extract_username(github_url: str) -> str | None:
    """Extract a GitHub username from a profile URL.

    Accepts forms like:
      - https://github.com/sabbir0x7
      - https://github.com/sabbir0x7/
      - https://www.github.com/sabbir0x7

    Returns ``None`` if the URL doesn't look like a GitHub profile.
    """
    parsed = urlparse(str(github_url))
    if parsed.hostname not in ("github.com", "www.github.com"):
        return None
    # Path is like "/sabbir0x7" or "/sabbir0x7/" or "/sabbir0x7/repo"
    parts = [p for p in parsed.path.split("/") if p]
    if not parts:
        return None
    username = parts[0]
    # Basic sanity: GitHub usernames are alphanumeric + hyphens, 1-39 chars
    if re.match(r"^[a-zA-Z0-9](?:[a-zA-Z0-9-]{0,37}[a-zA-Z0-9])?$", username):
        return username
    return None


def _fallback(github_url: str) -> dict[str, Any]:
    """Minimal fallback when the API is unreachable or returns an error."""
    return {
        "username": extract_username(github_url),
        "bio": None,
        "public_repos_count": None,
        "followers": None,
        "following": None,
        "top_languages": [],
        "repos": [],
        "fetch_success": False,
        "url": github_url,
    }


def _aggregate_languages(repos: list[dict[str, Any]]) -> list[tuple[str, int]]:
    """Count repos per language and return sorted (language, count) pairs."""
    counter: Counter[str] = Counter()
    for repo in repos:
        lang = repo.get("language")
        if lang:
            counter[lang] += 1
    return counter.most_common(10)


async def fetch_profile(github_url: str) -> dict[str, Any]:
    """Fetch a GitHub user's public profile and repos.

    Parameters
    ----------
    github_url:
        The full GitHub profile URL (e.g. ``https://github.com/sabbir0x7``).

    Returns
    -------
    dict
        Structured profile data with keys: username, bio, public_repos_count,
        followers, following, top_languages, repos, fetch_success, url.
    """
    username = extract_username(github_url)
    if not username:
        return _fallback(github_url)

    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, headers=_HEADERS) as client:
            # Fetch user metadata
            user_resp = await client.get(f"{_API_BASE}/users/{username}")
            if user_resp.status_code != 200:
                return _fallback(github_url)
            user_data = user_resp.json()

            # Fetch repos sorted by most recently updated
            repos_resp = await client.get(
                f"{_API_BASE}/users/{username}/repos",
                params={"sort": "updated", "per_page": _MAX_REPOS},
            )
            repos_raw: list[dict[str, Any]] = []
            if repos_resp.status_code == 200:
                repos_raw = repos_resp.json()

    except (httpx.HTTPError, httpx.TimeoutException, Exception):
        return _fallback(github_url)

    # Build structured repo list
    repos = [
        {
            "name": r.get("name", ""),
            "language": r.get("language"),
            "stars": r.get("stargazers_count", 0),
            "forks": r.get("forks_count", 0),
            "description": r.get("description") or "",
            "updated_at": r.get("updated_at", ""),
        }
        for r in repos_raw
        if not r.get("fork")  # Exclude forks for a cleaner signal
    ]

    top_languages = _aggregate_languages(repos_raw)

    return {
        "username": username,
        "bio": user_data.get("bio"),
        "public_repos_count": user_data.get("public_repos", 0),
        "followers": user_data.get("followers", 0),
        "following": user_data.get("following", 0),
        "top_languages": top_languages,
        "repos": repos[:_TOP_REPOS_IN_PROMPT],
        "fetch_success": True,
        "url": github_url,
    }


async def fetch_profile_with_token(github_token: str) -> dict[str, Any]:
    """Fetch a GitHub user's profile using an authenticated token.

    Uses the OAuth token for richer data including private repos and
    contribution stats that are not available via unauthenticated API calls.

    Parameters
    ----------
    github_token:
        A valid GitHub OAuth access token.

    Returns
    -------
    dict
        Structured profile data with keys: username, bio, public_repos_count,
        total_private_repos, followers, following, top_languages, repos,
        fetch_success, authenticated.
    """
    auth_headers = {
        **_HEADERS,
        "Authorization": f"Bearer {github_token}",
    }

    try:
        async with httpx.AsyncClient(timeout=_TIMEOUT, headers=auth_headers) as client:
            # Fetch authenticated user metadata (includes private repo counts)
            user_resp = await client.get(f"{_API_BASE}/user")
            if user_resp.status_code != 200:
                return {
                    "username": None,
                    "bio": None,
                    "public_repos_count": None,
                    "total_private_repos": None,
                    "followers": None,
                    "following": None,
                    "top_languages": [],
                    "repos": [],
                    "fetch_success": False,
                    "authenticated": True,
                }
            user_data = user_resp.json()

            # Fetch repos (includes private repos the user owns)
            repos_resp = await client.get(
                f"{_API_BASE}/user/repos",
                params={
                    "sort": "updated",
                    "per_page": _MAX_REPOS,
                    "type": "owner",
                },
            )
            repos_raw: list[dict[str, Any]] = []
            if repos_resp.status_code == 200:
                repos_raw = repos_resp.json()

    except (httpx.HTTPError, httpx.TimeoutException, Exception):
        return {
            "username": None,
            "bio": None,
            "public_repos_count": None,
            "total_private_repos": None,
            "followers": None,
            "following": None,
            "top_languages": [],
            "repos": [],
            "fetch_success": False,
            "authenticated": True,
        }

    # Build structured repo list (include private repos for richer analysis)
    repos = [
        {
            "name": r.get("name", ""),
            "language": r.get("language"),
            "stars": r.get("stargazers_count", 0),
            "forks": r.get("forks_count", 0),
            "description": r.get("description") or "",
            "private": r.get("private", False),
            "updated_at": r.get("updated_at", ""),
        }
        for r in repos_raw
        if not r.get("fork")
    ]

    top_languages = _aggregate_languages(repos_raw)

    return {
        "username": user_data.get("login"),
        "bio": user_data.get("bio"),
        "public_repos_count": user_data.get("public_repos", 0),
        "total_private_repos": user_data.get("total_private_repos", 0),
        "followers": user_data.get("followers", 0),
        "following": user_data.get("following", 0),
        "top_languages": top_languages,
        "repos": repos[:_TOP_REPOS_IN_PROMPT],
        "fetch_success": True,
        "authenticated": True,
        "url": user_data.get("html_url", ""),
    }
