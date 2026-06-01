"""Property tests for the OpenAI-compatible AI service.

Validates five universal invariants of `app.services.ai_service.run`:

* **Property 8** - exactly one outbound POST to ``{base_url}/chat/completions``
  with ``Authorization: Bearer <ai_key>``; no other URLs touched. Validates
  Requirements 4.1, 4.2, 4.3.
* **Property 9** - the messages payload contains a system instruction that
  names every key of :class:`AnalysisEnvelope` (``github_analysis``,
  ``linkedin_analysis``, ``skill_gaps``, ``suggestions``) and demands JSON
  output. Validates Requirement 4.4.
* **Property 10** - any envelope-valid AI response round-trips into the
  returned :class:`AnalysisEnvelope`. Validates Requirement 4.5.
* **Property 11** - malformed JSON or schema-invalid responses trigger
  exactly one retry; second failure raises :class:`AIEnvelopeError`.
  Validates Requirement 4.6.
* **Property 12** - non-2xx upstream raises :class:`UpstreamAIError` with
  the upstream ``status_code``. Validates Requirement 4.8.

Upstream HTTP is faked through :class:`httpx.MockTransport`, which the
service accepts via the documented ``transport=`` kwarg. Each test mints a
fresh transport so request capture stays isolated per Hypothesis example.
"""

from __future__ import annotations

import json
import secrets
from collections.abc import Iterator
from typing import Any
from uuid import uuid4

import httpx
import pytest
from hypothesis import HealthCheck, given, settings as h_settings, strategies as st

from app.schemas.analysis import AnalysisEnvelope, AnalysisRequest
from app.services.ai_service import (
    SYSTEM_INSTRUCTION,
    AIEnvelopeError,
    UpstreamAIError,
    run,
)


# ---------------------------------------------------------------------------
# Hermetic env: every Settings field is provided locally.
# ---------------------------------------------------------------------------


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-role-placeholder")
    monkeypatch.setenv(
        "SUPABASE_JWT_SECRET", "test-secret-" + secrets.token_urlsafe(8)
    )
    monkeypatch.setenv(
        "FERNET_KEYS", "Mj6ttjVWrIA5KiFpYnsot8BVpzPB8ABFZzlD_im4aAM="
    )
    monkeypatch.setenv("AI_MODEL_DEFAULT", "gpt-4o-mini")

    from app.core.config import get_settings

    get_settings.cache_clear()
    try:
        yield
    finally:
        get_settings.cache_clear()


# ---------------------------------------------------------------------------
# Common generators and helpers.
# ---------------------------------------------------------------------------


_https_url = st.sampled_from(
    [
        "https://api.openai.com/v1",
        "https://api.openai.com/v1/",
        "https://api.groq.com/openai/v1",
        "https://openrouter.ai/api/v1",
    ]
)

# AI keys live behind SettingsIn(min_length=8) bound. We constrain to ASCII
# tokens so the Authorization header is well-formed.
_ai_key = st.text(
    alphabet=st.characters(min_codepoint=33, max_codepoint=126),
    min_size=8,
    max_size=64,
)


def _mk_request() -> AnalysisRequest:
    """A schema-valid AnalysisRequest used as the inputs for each call."""
    return AnalysisRequest(
        github_url="https://github.com/example",
        linkedin_url="https://linkedin.com/in/example",
        goal="Become a Senior Backend Engineer",
    )


def _envelope_payload() -> dict[str, Any]:
    """A canned AnalysisEnvelope-shaped dict the AI is supposed to return."""
    return {
        "github_analysis": {"summary": "Active polyglot contributor."},
        "linkedin_analysis": {"summary": "Backend leadership signal."},
        "skill_gaps": [
            {"name": "system_design", "gap_level": "medium", "rationale": "scale exposure"},
        ],
        "suggestions": [
            {
                "title": "Lead a service migration",
                "description": "Own a non-trivial migration end to end.",
                "priority": "high",
            }
        ],
    }


def _ok_chat_response(body: dict[str, Any]) -> httpx.Response:
    """Wrap a JSON envelope into the OpenAI chat-completions reply shape."""
    return httpx.Response(
        200,
        json={
            "choices": [
                {"message": {"role": "assistant", "content": json.dumps(body)}}
            ]
        },
    )


def _bad_chat_response(content: str) -> httpx.Response:
    """An OpenAI-shaped reply whose content cannot be parsed as the envelope."""
    return httpx.Response(
        200,
        json={
            "choices": [
                {"message": {"role": "assistant", "content": content}}
            ]
        },
    )


PROPERTY_SETTINGS = h_settings(
    max_examples=50,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
    deadline=None,
)


# ---------------------------------------------------------------------------
# Property 8 - exactly one outbound POST with the user's key.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@PROPERTY_SETTINGS
@given(base_url=_https_url, ai_key=_ai_key)
async def test_run_issues_exactly_one_outbound_call_with_bearer_key(
    base_url: str, ai_key: str
) -> None:
    """Validates Requirements 4.1, 4.2, 4.3: one POST, right URL, Bearer header."""
    captured: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return _ok_chat_response(_envelope_payload())

    transport = httpx.MockTransport(handler)
    await run(
        _mk_request(),
        ai_key=ai_key,
        base_url=base_url,
        transport=transport,
    )

    # Exactly one outbound call; no GitHub or LinkedIn API calls were made.
    assert len(captured) == 1, [str(r.url) for r in captured]
    sent = captured[0]

    # URL is the OpenAI-compatible chat-completions endpoint, with no
    # double-slash on the join.
    expected_url = base_url.rstrip("/") + "/chat/completions"
    assert str(sent.url) == expected_url
    assert sent.method == "POST"

    # The user's exact AI key is on the Authorization header and nowhere
    # else (defensive: no key embedded in the body).
    assert sent.headers.get("Authorization") == f"Bearer {ai_key}"
    assert ai_key not in sent.content.decode("utf-8")


# ---------------------------------------------------------------------------
# Property 9 - prompt names every envelope key and demands JSON.
# ---------------------------------------------------------------------------


@pytest.mark.asyncio
@PROPERTY_SETTINGS
@given(base_url=_https_url, ai_key=_ai_key)
async def test_prompt_names_every_envelope_key_and_demands_json(
    base_url: str, ai_key: str
) -> None:
    """Validates Requirement 4.4: messages instruct the strict JSON schema."""
    captured: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return _ok_chat_response(_envelope_payload())

    transport = httpx.MockTransport(handler)
    await run(
        _mk_request(),
        ai_key=ai_key,
        base_url=base_url,
        transport=transport,
    )

    body = json.loads(captured[0].content)
    messages: list[dict[str, str]] = body["messages"]

    # The prompt must contain a system message naming every envelope key
    # AND requesting JSON output. We concatenate all system message contents
    # so multi-message prompts are covered.
    system_text = "\n".join(
        msg["content"] for msg in messages if msg.get("role") == "system"
    )
    for key in (
        "github_analysis",
        "linkedin_analysis",
        "skill_gaps",
        "suggestions",
    ):
        assert key in system_text, f"system instruction missing key {key!r}"
    # JSON demand: lowercase "json" anywhere in the system text suffices and
    # also mirrors the system instruction defined in `ai_service.py`.
    assert "JSON" in system_text or "json" in system_text
    # And the configured response_format mirrors the JSON contract.
    assert body.get("response_format") == {"type": "json_object"}
    # Sanity: the canonical SYSTEM_INSTRUCTION should be the first system
    # message - this catches accidental reordering.
    assert messages[0]["role"] == "system"
    assert messages[0]["content"] == SYSTEM_INSTRUCTION


# ---------------------------------------------------------------------------
# Property 10 - schema-valid AI responses round-trip into AnalysisEnvelope.
# ---------------------------------------------------------------------------


# Generators for envelope payloads. Lists are bounded to keep examples cheap.
_levels = st.sampled_from(["low", "medium", "high"])
_skill_gap = st.fixed_dictionaries(
    {
        "name": st.text(min_size=1, max_size=24),
        "gap_level": _levels,
        "rationale": st.text(min_size=1, max_size=64),
    }
)
_suggestion = st.fixed_dictionaries(
    {
        "title": st.text(min_size=1, max_size=24),
        "description": st.text(min_size=1, max_size=64),
        "priority": _levels,
    }
)
_envelope_strategy = st.fixed_dictionaries(
    {
        "github_analysis": st.dictionaries(
            keys=st.text(min_size=1, max_size=8),
            values=st.text(max_size=32),
            max_size=4,
        ),
        "linkedin_analysis": st.dictionaries(
            keys=st.text(min_size=1, max_size=8),
            values=st.text(max_size=32),
            max_size=4,
        ),
        "skill_gaps": st.lists(_skill_gap, max_size=3),
        "suggestions": st.lists(_suggestion, max_size=3),
    }
)


@pytest.mark.asyncio
@PROPERTY_SETTINGS
@given(envelope=_envelope_strategy)
async def test_schema_valid_responses_round_trip(envelope: dict[str, Any]) -> None:
    """Validates Requirement 4.5: any envelope-valid AI body parses and is returned."""
    transport = httpx.MockTransport(lambda req: _ok_chat_response(envelope))

    result = await run(
        _mk_request(),
        ai_key="sk-test-1234",
        base_url="https://api.openai.com/v1",
        transport=transport,
    )

    # The returned envelope should equal the original AI body, modulo
    # Pydantic normalization (no extra/missing fields, same shape).
    assert isinstance(result, AnalysisEnvelope)
    assert result.model_dump() == AnalysisEnvelope.model_validate(envelope).model_dump()


# ---------------------------------------------------------------------------
# Property 11 - malformed responses retry exactly once, then raise.
# ---------------------------------------------------------------------------


# A pool of strings that will *not* parse as a valid envelope. We mix:
# - non-JSON text
# - JSON whose shape is wrong (missing required keys, wrong types)
_bad_content = st.one_of(
    st.text(min_size=0, max_size=64),
    st.just("{not json"),
    st.just('{"github_analysis": "not_a_dict"}'),
    st.just('{"github_analysis": {}, "linkedin_analysis": {}}'),  # missing lists
    st.just(
        '{"github_analysis": {}, "linkedin_analysis": {}, '
        '"skill_gaps": [{"name": "x", "gap_level": "ULTRA", "rationale": "x"}], '
        '"suggestions": []}'
    ),  # gap_level outside Literal set
)


@pytest.mark.asyncio
@PROPERTY_SETTINGS
@given(first=_bad_content, second=_bad_content)
async def test_two_bad_responses_retry_once_then_raise_envelope_error(
    first: str, second: str
) -> None:
    """Validates Requirement 4.6: retry exactly once, then 502."""
    captured: list[httpx.Request] = []
    bodies = iter([first, second])

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        try:
            return _bad_chat_response(next(bodies))
        except StopIteration:  # pragma: no cover - third call would exceed retry budget
            return _bad_chat_response("STOP")

    transport = httpx.MockTransport(handler)
    with pytest.raises(AIEnvelopeError):
        await run(
            _mk_request(),
            ai_key="sk-test-1234",
            base_url="https://api.openai.com/v1",
            transport=transport,
        )

    # Exactly two calls: original attempt + one retry.
    assert len(captured) == 2

    # The retry carries an additional system "schema reminder" message;
    # the body must therefore be larger than the first request.
    second_body = json.loads(captured[1].content)
    second_messages = second_body["messages"]
    # System reminders are appended after the original user message so the
    # retry payload has at least one more system message than the first.
    first_body = json.loads(captured[0].content)
    assert len(second_messages) > len(first_body["messages"])


@pytest.mark.asyncio
@PROPERTY_SETTINGS
@given(first=_bad_content, envelope=_envelope_strategy)
async def test_bad_then_good_recovers_via_single_retry(
    first: str, envelope: dict[str, Any]
) -> None:
    """Validates Requirement 4.6: a successful retry yields the envelope."""
    captured: list[httpx.Request] = []
    responses = iter(
        [_bad_chat_response(first), _ok_chat_response(envelope)]
    )

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return next(responses)

    transport = httpx.MockTransport(handler)
    result = await run(
        _mk_request(),
        ai_key="sk-test-1234",
        base_url="https://api.openai.com/v1",
        transport=transport,
    )

    assert len(captured) == 2  # original + one retry
    assert isinstance(result, AnalysisEnvelope)


# ---------------------------------------------------------------------------
# Property 12 - upstream non-2xx maps to UpstreamAIError with status echoed.
# ---------------------------------------------------------------------------


_non_2xx = st.one_of(
    st.integers(min_value=400, max_value=499),
    st.integers(min_value=500, max_value=599),
)


@pytest.mark.asyncio
@PROPERTY_SETTINGS
@given(status_code=_non_2xx)
async def test_non_2xx_upstream_raises_upstream_ai_error(status_code: int) -> None:
    """Validates Requirement 4.8: non-2xx upstream surfaces with the status."""
    captured: list[httpx.Request] = []

    def handler(request: httpx.Request) -> httpx.Response:
        captured.append(request)
        return httpx.Response(status_code, json={"error": "nope"})

    transport = httpx.MockTransport(handler)
    with pytest.raises(UpstreamAIError) as info:
        await run(
            _mk_request(),
            ai_key="sk-test-1234",
            base_url="https://api.openai.com/v1",
            transport=transport,
        )

    # Upstream errors are not retried (Property 12 is distinct from Property
    # 11) - exactly one outbound call is expected.
    assert len(captured) == 1
    assert info.value.status_code == status_code
