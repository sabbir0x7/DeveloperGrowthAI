"""OpenAI-compatible chat-completions client for analysis runs.

This service is the single chokepoint for outbound AI traffic. It builds a
strict-schema prompt, POSTs to ``{base_url}/chat/completions`` using the
caller's own AI key, and validates the model's reply against the
:class:`~app.schemas.analysis.AnalysisEnvelope` Pydantic model.

Design intent:

* **Provider-agnostic.** The contract is the OpenAI ``/chat/completions``
  shape, so OpenAI, Groq, and OpenRouter all work without code changes -
  only ``base_url`` differs (Requirement 4.3).
* **No third-party scraping.** The service never calls the GitHub REST API
  or LinkedIn; the user-supplied URLs are passed verbatim into the prompt
  so the LLM is the sole interpreter (Requirement 4.2).
* **Strict envelope.** The system instruction names every key of
  :class:`AnalysisEnvelope` and requires JSON output (Requirement 4.4 /
  Property 9). The provider's ``response_format={"type":"json_object"}``
  parameter is requested as a belt-and-braces signal, but we still validate
  the body ourselves because not every provider honours it.
* **One retry on schema failure.** A parse error or Pydantic
  ``ValidationError`` triggers exactly one retry with a schema-reminder
  appended to the messages. A second failure is surfaced as
  :class:`AIEnvelopeError` (Requirement 4.6).
* **Upstream errors are not retried.** A non-2xx status from the provider
  is wrapped immediately as :class:`UpstreamAIError`, carrying the upstream
  status so the API layer can echo it to the client (Requirement 4.8).

The route handler in :mod:`app.api.v1.analysis` is responsible for
translating these exceptions into HTTP responses (502 with ``upstream_status``
for :class:`UpstreamAIError`, 502 ``ai_invalid_json`` for
:class:`AIEnvelopeError`).
"""

from __future__ import annotations

import json
from typing import Any

import httpx
from pydantic import ValidationError

from app.core.config import get_settings
from app.schemas.analysis import AnalysisEnvelope, AnalysisRequest

# 30-second wall clock per upstream call (Design §"AI service contract").
# Applied to the whole request lifecycle: connect + write + read + pool wait.
AI_REQUEST_TIMEOUT_SECONDS = 30.0

# Sampling temperature kept low so the provider returns deterministic,
# schema-shaped output instead of free-form prose (Design §"AI service
# contract"). Not a guarantee of correctness - that is what the envelope
# validation + one-retry policy enforces - but it improves the hit rate.
AI_TEMPERATURE = 0.2

# The system instruction. It explicitly names every key of
# :class:`AnalysisEnvelope` and demands JSON output, which is the invariant
# Property 9 checks.
SYSTEM_INSTRUCTION = (
    "You are an expert software engineering career coach. Analyze the "
    "candidate's GitHub profile, LinkedIn profile, and stated career goal, "
    "then respond with a single JSON object that strictly matches this "
    "schema. Do not include Markdown, commentary, or any keys outside the "
    "schema.\n\n"
    "Schema:\n"
    "{\n"
    '  "github_analysis": object,\n'
    '  "linkedin_analysis": object,\n'
    '  "skill_gaps": [\n'
    '    { "name": string, "gap_level": "low" | "medium" | "high", '
    '"rationale": string }\n'
    "  ],\n"
    '  "suggestions": [\n'
    '    { "title": string, "description": string, '
    '"priority": "low" | "medium" | "high", '
    '"timeline": string (e.g. "4-6 weeks"), '
    '"steps": [string] (week-by-week action items, 3-6 steps) }\n'
    "  ]\n"
    "}\n\n"
    "For each suggestion, provide a realistic timeline and concrete "
    "week-by-week steps the candidate should follow. "
    "Respond with valid JSON only."
)

# Appended on the second attempt when the first reply failed parse or schema
# validation. The reminder repeats the four envelope keys verbatim so a
# truncated or wandering model is forced back onto the contract.
SCHEMA_REMINDER = (
    "Your previous response did not parse against the required schema. "
    "Respond with a single JSON object containing exactly these keys: "
    "github_analysis (object), linkedin_analysis (object), skill_gaps "
    "(array of objects), suggestions (array of objects). Do not include "
    "any text outside the JSON object."
)


class UpstreamAIError(Exception):
    """Raised when the AI provider returns a non-2xx HTTP response.

    Carries the upstream status code so the API layer can echo it in the
    error body without leaking the provider's response payload (which may
    contain provider-specific error metadata that the client should not
    surface). The truncated body is retained for server-side logs only.
    """

    def __init__(self, status_code: int, body: str) -> None:
        super().__init__(f"upstream_ai_error:{status_code}")
        self.status_code = status_code
        # Keep the body bounded so a hostile provider cannot blow our log
        # budget by returning a multi-megabyte error page.
        self.body = body[:2048]


class AIEnvelopeError(Exception):
    """Raised when the AI's reply cannot be validated after one retry.

    Distinct from :class:`UpstreamAIError`: the provider answered with 2xx
    but the content was either not JSON or did not satisfy
    :class:`AnalysisEnvelope`. The route handler maps this to HTTP 502 with
    code ``ai_invalid_json`` (Requirement 4.6).
    """


def _build_user_message(
    inputs: AnalysisRequest,
    *,
    github_data: dict[str, Any] | None = None,
    linkedin_text: str | None = None,
) -> str:
    """Render the user's inputs into the chat user message.

    When ``github_data`` is provided (from the GitHub scraping service),
    the prompt includes structured profile data so the AI can produce a
    more accurate analysis. Falls back to just the URL when data is
    unavailable.

    When ``linkedin_text`` is provided (user-pasted summary/experience),
    it is included verbatim so the AI can analyze real LinkedIn content
    instead of just seeing a URL it cannot access.
    """
    parts: list[str] = []

    # --- GitHub section ---
    if github_data and github_data.get("fetch_success"):
        gh_lines = [
            "GitHub Profile Data:",
            f"  Username: {github_data.get('username', 'unknown')}",
        ]
        if github_data.get("bio"):
            gh_lines.append(f"  Bio: {github_data['bio']}")
        gh_lines.append(
            f"  Public Repos: {github_data.get('public_repos_count', 0)}"
        )
        gh_lines.append(f"  Followers: {github_data.get('followers', 0)}")
        gh_lines.append(f"  Following: {github_data.get('following', 0)}")

        top_langs = github_data.get("top_languages", [])
        if top_langs:
            lang_str = ", ".join(
                f"{lang} ({count} repos)" for lang, count in top_langs
            )
            gh_lines.append(f"  Top Languages: {lang_str}")

        repos = github_data.get("repos", [])
        if repos:
            gh_lines.append("  Recent Repos:")
            for repo in repos[:10]:
                lang = repo.get("language") or "N/A"
                stars = repo.get("stars", 0)
                desc = repo.get("description", "")
                name = repo.get("name", "")
                desc_part = f" - {desc}" if desc else ""
                gh_lines.append(
                    f"    - {name} ({lang}, ★{stars}){desc_part}"
                )

        parts.append("\n".join(gh_lines))
    else:
        parts.append(f"GitHub URL: {inputs.github_url}")

    # --- LinkedIn section ---
    if linkedin_text and linkedin_text.strip():
        parts.append(f"LinkedIn Profile:\n{linkedin_text.strip()}")
    else:
        parts.append(f"LinkedIn URL: {inputs.linkedin_url}")

    # --- Career goal ---
    parts.append(f"Career Goal: {inputs.goal}")

    return "\n\n".join(parts)


def _initial_messages(
    inputs: AnalysisRequest,
    *,
    github_data: dict[str, Any] | None = None,
    linkedin_text: str | None = None,
) -> list[dict[str, str]]:
    """Build the first-attempt message list (system + user)."""
    return [
        {"role": "system", "content": SYSTEM_INSTRUCTION},
        {
            "role": "user",
            "content": _build_user_message(
                inputs, github_data=github_data, linkedin_text=linkedin_text
            ),
        },
    ]


def _build_request_body(messages: list[dict[str, str]], model: str) -> dict[str, Any]:
    """Assemble the JSON body for ``POST /chat/completions``.

    ``response_format={"type":"json_object"}`` is the OpenAI-compatible
    request that the model produce a single JSON object. Providers that do
    not implement it ignore the field; the envelope validation below catches
    any divergence anyway.
    """
    return {
        "model": model,
        "messages": messages,
        "response_format": {"type": "json_object"},
        "temperature": AI_TEMPERATURE,
    }


def _completions_url(base_url: str) -> str:
    """Join ``base_url`` with ``/chat/completions`` without doubling slashes.

    Pydantic's ``HttpUrl`` may render a trailing slash on the host-only
    form (``https://example.com/``) but not on a pathful form
    (``https://example.com/v1``). ``rstrip("/")`` normalises both before
    we append.
    """
    return base_url.rstrip("/") + "/chat/completions"


def _extract_content(payload: dict[str, Any]) -> str:
    """Pull ``choices[0].message.content`` out of an OpenAI-shaped reply.

    Any structural deviation (missing ``choices``, empty list, missing
    ``message``, non-string ``content``) is normalized into a string-typed
    error so the caller's ``json.loads`` produces a clean
    :class:`AIEnvelopeError` instead of a generic ``KeyError`` /
    ``IndexError`` leaking up to the route layer.
    """
    choices = payload.get("choices")
    if not isinstance(choices, list) or not choices:
        raise _ContentExtractionError("missing_choices")
    first = choices[0]
    if not isinstance(first, dict):
        raise _ContentExtractionError("malformed_choice")
    message = first.get("message")
    if not isinstance(message, dict):
        raise _ContentExtractionError("missing_message")
    content = message.get("content")
    if not isinstance(content, str):
        raise _ContentExtractionError("missing_content")
    return content


class _ContentExtractionError(Exception):
    """Internal sentinel: the provider's envelope was unparseable.

    Never escapes this module; the caller catches it and converts it to an
    :class:`AIEnvelopeError` once the retry is exhausted, the same way it
    handles ``json.JSONDecodeError`` and Pydantic ``ValidationError``.
    """


def _parse_envelope(content: str) -> AnalysisEnvelope:
    """Decode ``content`` as JSON and validate it against the envelope.

    Two failure modes share a single exception path so the retry loop above
    can catch one type:

    * ``json.JSONDecodeError`` - the content is not JSON at all.
    * :class:`pydantic.ValidationError` - the content is JSON but does not
      match the strict schema (extra keys, wrong types, missing fields,
      ``gap_level`` outside the literal set, ...).
    """
    decoded = json.loads(content)
    return AnalysisEnvelope.model_validate(decoded)


async def _post_chat_completion(
    client: httpx.AsyncClient,
    *,
    url: str,
    ai_key: str,
    body: dict[str, Any],
) -> dict[str, Any]:
    """Issue one POST and translate non-2xx into :class:`UpstreamAIError`.

    The provider's API key is sent in the ``Authorization`` header exactly
    as the user supplied it. We never persist or log the key, and the only
    place it appears in this module is on this header; everything else
    operates on the parsed JSON.
    """
    response = await client.post(
        url,
        json=body,
        headers={
            "Authorization": f"Bearer {ai_key}",
            "Content-Type": "application/json",
        },
    )
    if response.status_code < 200 or response.status_code >= 300:
        # Read the body as text for diagnostics; bytes from a binary error
        # response are decoded with replacement so this never raises.
        raise UpstreamAIError(response.status_code, response.text)
    # ``response.json()`` lazily decodes; if the upstream sent non-JSON on
    # a 2xx (rare but possible for misbehaving proxies), the resulting
    # ``json.JSONDecodeError`` is caught by the envelope-parse retry loop.
    return response.json()


async def run(
    inputs: AnalysisRequest,
    *,
    ai_key: str,
    base_url: str,
    model: str | None = None,
    transport: httpx.AsyncBaseTransport | None = None,
    github_data: dict[str, Any] | None = None,
    linkedin_text: str | None = None,
) -> AnalysisEnvelope:
    """Run a single analysis against the user's OpenAI-compatible provider.

    Parameters
    ----------
    inputs:
        The validated request body (URLs + goal) the client supplied.
    ai_key:
        The user's decrypted AI provider key. Sent only in the upstream
        ``Authorization`` header; never returned, logged, or echoed back to
        the client. The route layer is responsible for ensuring this is
        populated (raising :class:`MissingAIKey` upstream if not).
    base_url:
        The provider's OpenAI-compatible base URL (e.g.
        ``https://api.openai.com/v1``). Validated as HTTPS at the schema
        layer (Requirement 6.7) before reaching this service.
    model:
        Optional model identifier. Defaults to the configured
        ``AI_MODEL_DEFAULT`` so callers can stay agnostic of the provider's
        catalogue.
    transport:
        Optional ``httpx.AsyncBaseTransport`` for tests. Production callers
        leave this ``None`` so a plain :class:`httpx.AsyncClient` with the
        configured timeout is used; tests pass an ``httpx.MockTransport``
        to assert on outbound requests without hitting the network.
    github_data:
        Optional structured GitHub profile data from the scraping service.
        When provided, the prompt includes real repo/language data instead
        of just the URL.
    linkedin_text:
        Optional user-pasted LinkedIn summary/experience text. When
        provided, the prompt includes the actual content for analysis.

    Returns
    -------
    AnalysisEnvelope
        The structured AI reply, ready for persistence and rendering.

    Raises
    ------
    UpstreamAIError
        The provider returned a non-2xx response on any attempt.
    AIEnvelopeError
        The provider returned 2xx twice (initial + one retry) but neither
        response parsed against :class:`AnalysisEnvelope`.
    """
    settings = get_settings()
    chosen_model = model or settings.AI_MODEL_DEFAULT
    url = _completions_url(base_url)
    messages = _initial_messages(
        inputs, github_data=github_data, linkedin_text=linkedin_text
    )

    timeout = httpx.Timeout(AI_REQUEST_TIMEOUT_SECONDS)
    async with httpx.AsyncClient(transport=transport, timeout=timeout) as client:
        # --- Attempt 1 ---------------------------------------------------
        # Upstream HTTP errors short-circuit out as ``UpstreamAIError``;
        # only schema/JSON failures fall into the retry branch below.
        payload = await _post_chat_completion(
            client,
            url=url,
            ai_key=ai_key,
            body=_build_request_body(messages, chosen_model),
        )
        try:
            content = _extract_content(payload)
            return _parse_envelope(content)
        except (_ContentExtractionError, json.JSONDecodeError, ValidationError):
            # Fall through to the single retry. We deliberately do not log
            # the offending content here - it may contain partial PII the
            # model echoed from the user's profile - but the route layer's
            # 502 response will tell the operator a schema failure occurred.
            pass

        # --- Attempt 2 (with reminder) -----------------------------------
        # Append the schema reminder as a fresh system message rather than
        # mutating the previous one: this preserves the original system +
        # user pair so the model sees the original task plus the corrective
        # nudge, which empirically yields better recovery than rewriting.
        reminder_messages = messages + [
            {"role": "system", "content": SCHEMA_REMINDER},
        ]
        retry_payload = await _post_chat_completion(
            client,
            url=url,
            ai_key=ai_key,
            body=_build_request_body(reminder_messages, chosen_model),
        )
        try:
            retry_content = _extract_content(retry_payload)
            return _parse_envelope(retry_content)
        except (_ContentExtractionError, json.JSONDecodeError, ValidationError) as exc:
            # Second failure is terminal. The route layer maps this to HTTP
            # 502 with the ``ai_invalid_json`` error code per Requirement 4.6.
            raise AIEnvelopeError("ai_invalid_json") from exc
