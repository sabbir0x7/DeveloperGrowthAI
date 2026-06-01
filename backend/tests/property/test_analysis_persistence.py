"""Property tests for analysis persistence and the latest-row read.

Validates three universal invariants of
:mod:`app.services.analysis_service`:

* **Property 13** - successful runs persist exactly one ``analyses`` row
  for the user, whose columns equal the request and whose ``result_json``
  equals the AI envelope. Validates Requirement 5.1.
* **Property 14** - ``skills`` and ``roadmaps`` upserts are
  union-preserving across multiple runs: repeated ``skill_gap`` names /
  ``suggestion`` titles collapse to a single row each. Validates
  Requirements 5.2, 5.3.
* **Property 15** - ``get_latest`` returns the row with the maximum
  ``created_at`` for the user. Validates Requirement 5.4.

We use the same Supabase double pattern established in
`tests/test_settings_service.py`: a tiny in-memory client that mimics the
chained ``client.table(...).insert/upsert/select.eq.order.limit.execute()``
builder so the service exercises the real call path without a real database.
"""

from __future__ import annotations

import secrets
from collections.abc import Iterator
from dataclasses import dataclass, field
from datetime import datetime, timedelta, timezone
from typing import Any
from uuid import UUID, uuid4

import pytest
from cryptography.fernet import Fernet
from hypothesis import HealthCheck, given, settings as h_settings, strategies as st

from app.schemas.analysis import (
    AnalysisEnvelope,
    AnalysisRequest,
    SkillGap,
    Suggestion,
)


_FERNET_KEY = Fernet.generate_key().decode("utf-8")


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-role-placeholder")
    monkeypatch.setenv(
        "SUPABASE_JWT_SECRET", "test-secret-" + secrets.token_urlsafe(8)
    )
    monkeypatch.setenv("FERNET_KEYS", _FERNET_KEY)
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
# Supabase double
# ---------------------------------------------------------------------------


@dataclass
class _ExecuteResult:
    data: list[dict[str, Any]]


@dataclass
class _SelectBuilder:
    rows: list[dict[str, Any]]
    filters: list[tuple[str, Any]] = field(default_factory=list)
    order_key: str | None = None
    order_desc: bool = False
    limit_n: int | None = None
    columns: str = "*"

    def select(self, columns: str) -> "_SelectBuilder":
        self.columns = columns
        return self

    def eq(self, column: str, value: Any) -> "_SelectBuilder":
        self.filters.append((column, value))
        return self

    def order(self, column: str, *, desc: bool = False) -> "_SelectBuilder":
        self.order_key = column
        self.order_desc = desc
        return self

    def limit(self, n: int) -> "_SelectBuilder":
        self.limit_n = n
        return self

    def execute(self) -> _ExecuteResult:
        # Apply equality filters.
        rows = list(self.rows)
        for col, val in self.filters:
            rows = [r for r in rows if r.get(col) == val]
        # Order, if requested.
        if self.order_key is not None:
            rows.sort(
                key=lambda r: r.get(self.order_key) or "",
                reverse=self.order_desc,
            )
        if self.limit_n is not None:
            rows = rows[: self.limit_n]
        return _ExecuteResult(data=rows)


@dataclass
class _MutationBuilder:
    """Captures insert/upsert and applies them to the table's row buffer."""

    rows: list[dict[str, Any]]
    payload: list[dict[str, Any]]
    is_upsert: bool
    on_conflict: str | None = None

    def execute(self) -> _ExecuteResult:
        if self.is_upsert and self.on_conflict:
            keys = [k.strip() for k in self.on_conflict.split(",")]
            for new in self.payload:
                # Find existing row matching on the conflict-key tuple.
                match_idx: int | None = None
                for idx, existing in enumerate(self.rows):
                    if all(existing.get(k) == new.get(k) for k in keys):
                        match_idx = idx
                        break
                if match_idx is None:
                    self.rows.append(dict(new))
                else:
                    # Upsert overwrites the matching row.
                    self.rows[match_idx] = dict(new)
        else:
            for new in self.payload:
                self.rows.append(dict(new))
        return _ExecuteResult(data=list(self.payload))


@dataclass
class _FakeTable:
    rows: list[dict[str, Any]] = field(default_factory=list)

    def select(self, columns: str) -> _SelectBuilder:
        return _SelectBuilder(rows=self.rows, columns=columns)

    def insert(self, payload: dict[str, Any] | list[dict[str, Any]]) -> _MutationBuilder:
        records = payload if isinstance(payload, list) else [payload]
        return _MutationBuilder(
            rows=self.rows,
            payload=list(records),
            is_upsert=False,
        )

    def upsert(
        self,
        payload: dict[str, Any] | list[dict[str, Any]],
        *,
        on_conflict: str | None = None,
    ) -> _MutationBuilder:
        records = payload if isinstance(payload, list) else [payload]
        return _MutationBuilder(
            rows=self.rows,
            payload=list(records),
            is_upsert=True,
            on_conflict=on_conflict,
        )


@dataclass
class _FakeSupabase:
    tables: dict[str, _FakeTable] = field(default_factory=dict)

    def table(self, name: str) -> _FakeTable:
        return self.tables.setdefault(name, _FakeTable(rows=[]))


# ---------------------------------------------------------------------------
# Fixtures wiring the analysis service to the fake Supabase + fake AI service
# ---------------------------------------------------------------------------


def _seed_settings(fake: _FakeSupabase, user_id: UUID, plaintext_key: str = "sk-test-1234") -> None:
    """Plant a settings row so `get_decrypted_key`/`get_settings` succeed."""
    from app.core.encryption import get_encryption_service

    fake.tables.setdefault("user_settings", _FakeTable(rows=[])).rows.append(
        {
            "user_id": str(user_id),
            "encrypted_ai_key": "\\x"
            + get_encryption_service().encrypt(plaintext_key).hex(),
            "ai_provider_base_url": "https://api.openai.com/v1",
        }
    )


def _patch_settings_service(monkeypatch: pytest.MonkeyPatch, fake: _FakeSupabase) -> None:
    """Route `settings_service.get_supabase` to the fake.

    `settings_service` doesn't accept a client kwarg, so it's the only
    piece of the analysis pipeline that resolves the singleton on its own.
    We redirect it to the same fake so settings reads land in the same
    in-memory store the analysis service writes to.
    """
    from app.services import settings_service

    monkeypatch.setattr(settings_service, "get_supabase", lambda: fake)


def _patch_github_service(monkeypatch: pytest.MonkeyPatch) -> None:
    """Patch github_service.fetch_profile to avoid real HTTP calls in tests."""
    from app.services import analysis_service

    async def _fake_fetch_profile(url: str) -> dict:
        return {
            "username": "example",
            "bio": None,
            "public_repos_count": 5,
            "followers": 2,
            "following": 1,
            "top_languages": [("Python", 3)],
            "repos": [],
            "fetch_success": True,
            "url": url,
        }

    monkeypatch.setattr(analysis_service.github_service, "fetch_profile", _fake_fetch_profile)


def _request() -> AnalysisRequest:
    return AnalysisRequest(
        github_url="https://github.com/example",
        linkedin_url="https://linkedin.com/in/example",
        goal="Become a Senior Backend Engineer",
    )


def _envelope(skills: list[SkillGap], suggestions: list[Suggestion]) -> AnalysisEnvelope:
    return AnalysisEnvelope(
        github_analysis={"summary": "x"},
        linkedin_analysis={"summary": "y"},
        skill_gaps=skills,
        suggestions=suggestions,
    )


PROPERTY_SETTINGS = h_settings(
    max_examples=50,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
    deadline=None,
)


# ---------------------------------------------------------------------------
# Generators
# ---------------------------------------------------------------------------


_levels = st.sampled_from(["low", "medium", "high"])


def _skill_gap_strategy(name: str | None = None) -> st.SearchStrategy[SkillGap]:
    name_strat = st.just(name) if name is not None else st.text(min_size=1, max_size=24)
    return st.builds(
        SkillGap,
        name=name_strat,
        gap_level=_levels,
        rationale=st.text(min_size=1, max_size=64),
    )


def _suggestion_strategy(title: str | None = None) -> st.SearchStrategy[Suggestion]:
    title_strat = st.just(title) if title is not None else st.text(min_size=1, max_size=24)
    return st.builds(
        Suggestion,
        title=title_strat,
        description=st.text(min_size=1, max_size=64),
        priority=_levels,
    )


# ---------------------------------------------------------------------------
# Property 13 - exactly one analyses row inserted with matching columns.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@PROPERTY_SETTINGS
@given(
    skills=st.lists(_skill_gap_strategy(), max_size=4),
    suggestions=st.lists(_suggestion_strategy(), max_size=4),
)
async def test_run_persists_exactly_one_analyses_row(
    monkeypatch: pytest.MonkeyPatch,
    skills: list[SkillGap],
    suggestions: list[Suggestion],
) -> None:
    """Validates Requirement 5.1: one new row, columns match the request."""
    from app.services import analysis_service

    fake = _FakeSupabase()
    user_id = uuid4()
    _seed_settings(fake, user_id)
    _patch_settings_service(monkeypatch, fake)
    _patch_github_service(monkeypatch)

    envelope = _envelope(skills, suggestions)

    async def fake_ai_run(_inputs, *, ai_key, base_url, **_kwargs):
        return envelope

    monkeypatch.setattr(analysis_service.ai_service, "run", fake_ai_run)

    req = _request()
    response = await analysis_service.run(user_id, req, client=fake)

    rows = fake.tables[analysis_service._ANALYSES_TABLE].rows
    user_rows = [r for r in rows if r["user_id"] == str(user_id)]
    assert len(user_rows) == 1
    persisted = user_rows[0]

    # Column-by-column match against the request.
    assert persisted["goal"] == req.goal
    assert persisted["github_url"].rstrip("/") == str(req.github_url).rstrip("/")
    assert persisted["linkedin_url"].rstrip("/") == str(req.linkedin_url).rstrip("/")

    # result_json is the full envelope.
    assert persisted["result_json"] == envelope.model_dump(mode="json")

    # The response carries the same id and the envelope contents.
    assert str(response.id) == persisted["id"]
    assert response.skill_gaps == envelope.skill_gaps
    assert response.suggestions == envelope.suggestions


# ---------------------------------------------------------------------------
# Property 14 - skills and roadmaps upserts are union-preserving.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@PROPERTY_SETTINGS
@given(
    name_a=st.text(min_size=1, max_size=12),
    name_b=st.text(min_size=1, max_size=12),
    name_c=st.text(min_size=1, max_size=12),
    title_a=st.text(min_size=1, max_size=12),
    title_b=st.text(min_size=1, max_size=12),
    title_c=st.text(min_size=1, max_size=12),
)
async def test_skill_and_roadmap_upserts_are_union_preserving(
    monkeypatch: pytest.MonkeyPatch,
    name_a: str,
    name_b: str,
    name_c: str,
    title_a: str,
    title_b: str,
    title_c: str,
) -> None:
    """Validates Requirements 5.2, 5.3: upserts collapse duplicates by key."""
    from app.services import analysis_service

    # Distinct names per analysis run so the union math is well-defined; if
    # Hypothesis happens to draw collisions we let them be (a re-upsert of
    # the same name should still leave a single row).
    fake = _FakeSupabase()
    user_id = uuid4()
    _seed_settings(fake, user_id)
    _patch_settings_service(monkeypatch, fake)
    _patch_github_service(monkeypatch)

    # First run: gaps {A, B}, suggestions {Ta, Tb}.
    first_skills = [
        SkillGap(name=name_a, gap_level="low", rationale="r"),
        SkillGap(name=name_b, gap_level="medium", rationale="r"),
    ]
    first_suggestions = [
        Suggestion(title=title_a, description="d", priority="low"),
        Suggestion(title=title_b, description="d", priority="medium"),
    ]

    # Second run: gaps {B, C}, suggestions {Tb, Tc}.
    second_skills = [
        SkillGap(name=name_b, gap_level="high", rationale="r"),
        SkillGap(name=name_c, gap_level="low", rationale="r"),
    ]
    second_suggestions = [
        Suggestion(title=title_b, description="d", priority="high"),
        Suggestion(title=title_c, description="d", priority="low"),
    ]

    envelopes = iter(
        [
            _envelope(first_skills, first_suggestions),
            _envelope(second_skills, second_suggestions),
        ]
    )

    async def fake_ai_run(_inputs, *, ai_key, base_url, **_kwargs):
        return next(envelopes)

    monkeypatch.setattr(analysis_service.ai_service, "run", fake_ai_run)

    await analysis_service.run(user_id, _request(), client=fake)
    await analysis_service.run(user_id, _request(), client=fake)

    expected_skill_names = {name_a, name_b, name_c}
    expected_titles = {title_a, title_b, title_c}

    skill_rows = fake.tables[analysis_service._SKILLS_TABLE].rows
    user_skill_rows = [r for r in skill_rows if r["user_id"] == str(user_id)]
    skill_names = {r["name"] for r in user_skill_rows}
    assert skill_names == expected_skill_names
    # Each name appears exactly once.
    assert len(user_skill_rows) == len(expected_skill_names)

    roadmap_rows = fake.tables[analysis_service._ROADMAPS_TABLE].rows
    user_roadmap_rows = [r for r in roadmap_rows if r["user_id"] == str(user_id)]
    roadmap_titles = {r["title"] for r in user_roadmap_rows}
    assert roadmap_titles == expected_titles
    assert len(user_roadmap_rows) == len(expected_titles)


# ---------------------------------------------------------------------------
# Property 15 - get_latest returns the row with the maximum created_at.
# ---------------------------------------------------------------------------


@PROPERTY_SETTINGS
@given(count=st.integers(min_value=2, max_value=6))
def test_get_latest_returns_row_with_max_created_at(count: int) -> None:
    """Validates Requirement 5.4: latest is the strict argmax of created_at."""
    from app.services import analysis_service

    fake = _FakeSupabase()
    user_id = uuid4()

    # Seed `count` rows with strictly increasing created_at so the argmax
    # is unambiguous. The "latest" envelope deliberately differs from the
    # others so we can confirm get_latest returns *that* one.
    base_time = datetime(2024, 1, 1, tzinfo=timezone.utc)
    rows: list[dict[str, Any]] = []
    latest_id: UUID | None = None
    latest_envelope: AnalysisEnvelope | None = None

    for i in range(count):
        envelope = AnalysisEnvelope(
            github_analysis={"i": str(i)},
            linkedin_analysis={"i": str(i)},
            skill_gaps=[],
            suggestions=[],
        )
        row_id = uuid4()
        rows.append(
            {
                "id": str(row_id),
                "user_id": str(user_id),
                "goal": f"goal {i}",
                "github_url": "https://github.com/example",
                "linkedin_url": "https://linkedin.com/in/example",
                "result_json": envelope.model_dump(mode="json"),
                "created_at": (base_time + timedelta(seconds=i)).isoformat(),
            }
        )
        latest_id = row_id
        latest_envelope = envelope

    # Also seed a competing user's analyses to confirm the user_id filter.
    other_user = uuid4()
    rows.append(
        {
            "id": str(uuid4()),
            "user_id": str(other_user),
            "goal": "noise",
            "github_url": "https://github.com/x",
            "linkedin_url": "https://linkedin.com/in/x",
            "result_json": AnalysisEnvelope(
                github_analysis={"i": "other"},
                linkedin_analysis={"i": "other"},
                skill_gaps=[],
                suggestions=[],
            ).model_dump(mode="json"),
            "created_at": (base_time + timedelta(days=10)).isoformat(),
        }
    )

    fake.tables[analysis_service._ANALYSES_TABLE] = _FakeTable(rows=rows)

    latest = analysis_service.get_latest(user_id, client=fake)

    assert latest is not None
    assert latest_id is not None and latest_envelope is not None
    assert latest.id == latest_id
    assert latest.github_analysis == latest_envelope.github_analysis


def test_get_latest_returns_none_when_no_rows_for_user() -> None:
    """Empty rows for the user yield None so the API can render 204."""
    from app.services import analysis_service

    fake = _FakeSupabase()
    fake.tables[analysis_service._ANALYSES_TABLE] = _FakeTable(rows=[])
    assert analysis_service.get_latest(uuid4(), client=fake) is None
