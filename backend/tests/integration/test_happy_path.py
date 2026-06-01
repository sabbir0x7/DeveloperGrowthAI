"""End-to-end happy-path integration test.

Validates the full user flow through the API:
    authenticate → PATCH /profile/me → PUT /profile/settings →
    POST /analysis/run → GET /analysis/latest

Each step asserts the expected status code and response shape.

Requirements covered: 1.4, 2.2, 4.5, 5.1, 5.4, 6.2.
"""

from __future__ import annotations

import json
import secrets
import time
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

import httpx
import pytest
from fastapi.testclient import TestClient
from jose import jwt

JWT_SECRET = "test-happy-path-secret-" + secrets.token_urlsafe(16)
FERNET_KEY = "Mj6ttjVWrIA5KiFpYnsot8BVpzPB8ABFZzlD_im4aAM="
AUDIENCE = "authenticated"


# ---------------------------------------------------------------------------
# Canned AI response — a schema-valid AnalysisEnvelope
# ---------------------------------------------------------------------------

CANNED_ENVELOPE = {
    "github_analysis": {
        "summary": "Active contributor with strong Python skills.",
        "top_languages": ["Python", "TypeScript"],
    },
    "linkedin_analysis": {
        "summary": "Mid-level engineer with 4 years experience.",
        "current_role": "Software Engineer",
    },
    "skill_gaps": [
        {
            "name": "System Design",
            "gap_level": "high",
            "rationale": "No evidence of large-scale architecture work.",
        },
        {
            "name": "Leadership",
            "gap_level": "medium",
            "rationale": "Limited mentoring or team-lead experience.",
        },
    ],
    "suggestions": [
        {
            "title": "Contribute to open-source infra projects",
            "description": "Build distributed systems experience through OSS.",
            "priority": "high",
        },
        {
            "title": "Start a tech blog",
            "description": "Document learnings to build thought leadership.",
            "priority": "medium",
        },
    ],
}


# ---------------------------------------------------------------------------
# Env fixture
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# JWT helper
# ---------------------------------------------------------------------------


def _mint_token(subject: str) -> str:
    """Mint a valid Supabase-style HS256 JWT."""
    now = int(time.time())
    return jwt.encode(
        {
            "sub": subject,
            "aud": AUDIENCE,
            "iat": now,
            "exp": now + 3600,
            "email": "user@example.com",
        },
        JWT_SECRET,
        algorithm="HS256",
    )


# ---------------------------------------------------------------------------
# In-memory Supabase fake
# ---------------------------------------------------------------------------


@dataclass
class _ExecuteResult:
    data: list[dict[str, Any]]


@dataclass
class _FakeQuery:
    """Supports the chained select/eq/limit/order/single/execute pattern."""

    rows: list[dict[str, Any]]
    _filters: list[tuple[str, Any]] = field(default_factory=list)
    _single: bool = False

    def select(self, _columns: str) -> "_FakeQuery":
        return self

    def eq(self, column: str, value: Any) -> "_FakeQuery":
        self._filters.append((column, value))
        return self

    def limit(self, _n: int) -> "_FakeQuery":
        return self

    def order(self, _column: str, **_kwargs: Any) -> "_FakeQuery":
        return self

    def single(self) -> "_FakeQuery":
        self._single = True
        return self

    def execute(self) -> _ExecuteResult:
        # Apply filters
        result = self.rows
        for col, val in self._filters:
            result = [r for r in result if str(r.get(col)) == str(val)]
        # .single() makes PostgREST return a single object, not an array
        if self._single and result:
            return _ExecuteResult(data=result[0])
        return _ExecuteResult(data=list(result))


@dataclass
class _FakeTable:
    """Supports select, insert, upsert, update with chaining."""

    rows: list[dict[str, Any]] = field(default_factory=list)
    _last_query: _FakeQuery | None = None

    def select(self, columns: str) -> _FakeQuery:
        q = _FakeQuery(rows=list(self.rows))
        self._last_query = q
        return q

    def insert(self, payload: dict[str, Any]) -> "_FakeTable":
        self.rows.append(dict(payload))
        return self

    def upsert(self, payload: Any, **_kwargs: Any) -> "_FakeTable":
        if isinstance(payload, dict):
            self.rows.append(dict(payload))
        elif isinstance(payload, list):
            self.rows.extend(dict(p) for p in payload)
        return self

    def update(self, payload: dict[str, Any]) -> _FakeQuery:
        # Apply update to all rows and return them
        for row in self.rows:
            row.update(payload)
        return _FakeQuery(rows=list(self.rows))

    def execute(self) -> _ExecuteResult:
        return _ExecuteResult(data=list(self.rows))


@dataclass
class _FakeSupabase:
    """Top-level fake exposing `.table(name)` like the real client."""

    tables: dict[str, _FakeTable] = field(default_factory=dict)

    def table(self, name: str) -> _FakeTable:
        return self.tables.setdefault(name, _FakeTable())


# ---------------------------------------------------------------------------
# Mock AI transport
# ---------------------------------------------------------------------------


def _make_ai_mock_transport() -> httpx.MockTransport:
    """Return an httpx.MockTransport that returns a canned AnalysisEnvelope."""

    def _handler(request: httpx.Request) -> httpx.Response:
        # Return a valid OpenAI-shaped chat completion response
        response_body = {
            "id": "chatcmpl-test",
            "object": "chat.completion",
            "created": int(time.time()),
            "model": "gpt-4o-mini",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": json.dumps(CANNED_ENVELOPE),
                    },
                    "finish_reason": "stop",
                }
            ],
            "usage": {"prompt_tokens": 100, "completion_tokens": 200, "total_tokens": 300},
        }
        return httpx.Response(200, json=response_body)

    return httpx.MockTransport(_handler)


# ---------------------------------------------------------------------------
# Happy-path integration test
# ---------------------------------------------------------------------------


def test_happy_path_flow(monkeypatch: pytest.MonkeyPatch) -> None:
    """Full user flow: auth → patch profile → put settings → run analysis → get latest.

    Validates Requirements 1.4, 2.2, 4.5, 5.1, 5.4, 6.2.
    """
    user_id = uuid4()
    token = _mint_token(str(user_id))
    headers = {"Authorization": f"Bearer {token}"}

    # Set up the in-memory Supabase fake
    fake_supabase = _FakeSupabase()

    # Seed the users table with a profile row
    fake_supabase.tables["users"] = _FakeTable(
        rows=[
            {
                "id": str(user_id),
                "email": "user@example.com",
                "full_name": None,
                "github_url": "https://github.com/old-handle",
                "linkedin_url": "https://linkedin.com/in/old-handle",
                "goal": "Old goal",
                "created_at": datetime.now(tz=timezone.utc).isoformat(),
            }
        ]
    )

    # Patch Supabase client in all service modules
    from app.core import supabase_client
    from app.services import ai_service, analysis_service, profile_service, settings_service, github_service

    monkeypatch.setattr(supabase_client, "get_supabase", lambda: fake_supabase)
    monkeypatch.setattr(settings_service, "get_supabase", lambda: fake_supabase)
    monkeypatch.setattr(analysis_service, "get_supabase", lambda: fake_supabase)
    monkeypatch.setattr(profile_service, "get_supabase", lambda: fake_supabase)

    # Patch the GitHub service to avoid real HTTP calls
    async def fake_fetch_profile(url):
        return {
            "username": "new-handle",
            "bio": "Test bio",
            "public_repos_count": 10,
            "followers": 5,
            "following": 3,
            "top_languages": [("Python", 5), ("TypeScript", 3)],
            "repos": [
                {"name": "test-repo", "language": "Python", "stars": 2, "forks": 0, "description": "A test repo", "updated_at": "2024-01-01T00:00:00Z"}
            ],
            "fetch_success": True,
            "url": url,
        }

    monkeypatch.setattr(github_service, "fetch_profile", fake_fetch_profile)

    # Patch the AI service to use our mock transport
    mock_transport = _make_ai_mock_transport()
    original_run = ai_service.run

    async def patched_ai_run(inputs, *, ai_key, base_url, model=None, transport=None, github_data=None, linkedin_text=None):
        return await original_run(
            inputs, ai_key=ai_key, base_url=base_url, model=model, transport=mock_transport,
            github_data=github_data, linkedin_text=linkedin_text,
        )

    monkeypatch.setattr(ai_service, "run", patched_ai_run)

    from app.main import create_app

    app = create_app()
    client = TestClient(app)

    # ---------------------------------------------------------------
    # Step 1: Authenticate — verify JWT works (Requirement 1.4)
    # GET /profile/me should return 200 with the seeded profile
    # ---------------------------------------------------------------
    resp = client.get("/api/v1/profile/me", headers=headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["id"] == str(user_id)
    assert body["email"] == "user@example.com"

    # ---------------------------------------------------------------
    # Step 2: PATCH /profile/me — set URLs + goal (Requirement 2.2)
    # ---------------------------------------------------------------
    patch_payload = {
        "github_url": "https://github.com/new-handle",
        "linkedin_url": "https://linkedin.com/in/new-handle",
        "goal": "Become a Staff Engineer",
    }
    resp = client.patch("/api/v1/profile/me", headers=headers, json=patch_payload)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["goal"] == "Become a Staff Engineer"
    assert "github.com/new-handle" in str(body["github_url"])
    assert "linkedin.com/in/new-handle" in str(body["linkedin_url"])

    # ---------------------------------------------------------------
    # Step 3: PUT /profile/settings — set AI key (Requirement 6.2)
    # ---------------------------------------------------------------
    ai_key = "sk-test-" + secrets.token_urlsafe(32)
    resp = client.put(
        "/api/v1/profile/settings",
        headers=headers,
        json={
            "ai_key": ai_key,
            "ai_provider_base_url": "https://api.openai.com/v1",
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["has_ai_key"] is True
    assert "openai.com" in str(body["ai_provider_base_url"])
    # The key must never appear in the response (Requirement 6.5)
    assert ai_key not in resp.text

    # ---------------------------------------------------------------
    # Step 4: POST /analysis/run (Requirements 4.5, 5.1)
    # ---------------------------------------------------------------
    resp = client.post(
        "/api/v1/analysis/run",
        headers=headers,
        json={
            "github_url": "https://github.com/new-handle",
            "linkedin_url": "https://linkedin.com/in/new-handle",
            "goal": "Become a Staff Engineer",
        },
    )
    assert resp.status_code == 200, resp.text
    body = resp.json()
    # Validate AnalysisResponse shape
    assert "id" in body
    assert "created_at" in body
    assert "github_analysis" in body
    assert "linkedin_analysis" in body
    assert "skill_gaps" in body
    assert "suggestions" in body
    assert len(body["skill_gaps"]) == 2
    assert len(body["suggestions"]) == 2
    assert body["skill_gaps"][0]["name"] == "System Design"
    assert body["skill_gaps"][0]["gap_level"] == "high"
    assert body["suggestions"][0]["title"] == "Contribute to open-source infra projects"
    assert body["suggestions"][0]["priority"] == "high"
    analysis_id = body["id"]

    # ---------------------------------------------------------------
    # Step 5: GET /analysis/latest (Requirement 5.4)
    # ---------------------------------------------------------------
    resp = client.get("/api/v1/analysis/latest", headers=headers)
    assert resp.status_code == 200, resp.text
    body = resp.json()
    assert body["id"] == analysis_id
    assert "github_analysis" in body
    assert "linkedin_analysis" in body
    assert "skill_gaps" in body
    assert "suggestions" in body
    assert body["created_at"] is not None
