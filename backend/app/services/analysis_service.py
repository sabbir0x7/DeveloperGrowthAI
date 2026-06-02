"""Analysis orchestration: AI run plus persistence fan-out.

This module is the single chokepoint between an inbound ``POST
/api/v1/analysis/run`` and the data layer. It coordinates four moves:

1. Pull the user's encrypted AI key and provider base URL from
   :mod:`app.services.settings_service`. A missing key short-circuits with
   :class:`~app.services.settings_service.MissingAIKey`, which the route
   layer translates into HTTP 412 ``ai_key_missing`` (Requirement 4.7).
2. Call :func:`app.services.ai_service.run` to obtain an
   :class:`AnalysisEnvelope`. Upstream errors and JSON-shape failures are
   raised as :class:`UpstreamAIError` / :class:`AIEnvelopeError` and
   surface unchanged to the route layer.
3. Persist exactly one row into ``analyses`` carrying the inputs and the
   full envelope as ``result_json`` (Requirement 5.1 / Property 13).
4. Upsert each ``skill_gap`` into ``skills`` (unique by ``user_id, name``)
   and each ``suggestion`` into ``roadmaps`` (unique by ``user_id, title``)
   so repeated analyses with overlapping items remain duplicate-free
   (Requirements 5.2, 5.3 / Property 14).

Read path:
:func:`get_latest` returns the user's most recent ``analyses`` row -
ordered by ``created_at`` descending - reconstructed back into the public
:class:`AnalysisResponse` shape so the dashboard can render the empty or
filled state without a second round trip (Requirement 5.4 / Property 15).

Notes
-----
* The Supabase service-role client bypasses RLS, so every query in this
  module includes a ``user_id`` filter; the service layer is the only
  thing keeping a logged-in user from reading another's analyses.
* All inputs hitting this module are already validated by Pydantic
  schemas at the route boundary, so we do not re-check shapes here.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import UUID, uuid4

from supabase import Client

from app.core.supabase_client import get_supabase
from app.schemas.analysis import (
    AnalysisEnvelope,
    AnalysisRequest,
    AnalysisResponse,
)
from app.services import ai_service, settings_service, github_service

# Table names live as constants so tests can stub the chained builders by
# table name without importing more than necessary from this module.
_ANALYSES_TABLE = "analyses"
_SKILLS_TABLE = "skills"
_ROADMAPS_TABLE = "roadmaps"


def _now_iso() -> str:
    """Timezone-aware ISO timestamp for ``timestamptz`` columns.

    PostgREST accepts ISO-8601 strings on the wire and converts them into
    ``timestamptz`` in the database. Using ``datetime.now(timezone.utc)``
    keeps the value monotonic and unambiguous regardless of the host clock
    settings.
    """
    return datetime.now(timezone.utc).isoformat()


def _serialize_envelope(envelope: AnalysisEnvelope) -> dict[str, Any]:
    """Convert an :class:`AnalysisEnvelope` into a JSON-able dict.

    ``mode="json"`` ensures every nested type (e.g., the ``Literal`` enums
    on :class:`SkillGap` and :class:`Suggestion`) lands as plain strings,
    which matches the ``jsonb`` column shape and the wire contract.
    """
    return envelope.model_dump(mode="json")


async def run(
    user_id: UUID,
    request: AnalysisRequest,
    *,
    client: Client | None = None,
) -> AnalysisResponse:
    """Run a fresh analysis and persist the result.

    Parameters
    ----------
    user_id:
        The authenticated caller (extracted from the JWT in the route).
    request:
        The validated request body (URLs and goal). Pydantic has already
        rejected non-HTTPS URLs and bounded the goal length, so this
        function trusts the shape.
    client:
        Optional Supabase client override for tests. Production code omits
        it and picks up the singleton.

    Returns
    -------
    AnalysisResponse
        The full envelope plus the persistence-side ``id`` and
        ``created_at`` columns assigned to the new ``analyses`` row.

    Raises
    ------
    MissingAIKey
        Re-raised from :mod:`settings_service` when the user has no key.
    UpstreamAIError
        Re-raised from :mod:`ai_service` on a non-2xx provider response.
    AIEnvelopeError
        Re-raised from :mod:`ai_service` when the model's reply cannot be
        validated after one retry.
    """
    sb = client if client is not None else get_supabase()

    # Step 1: pull the decrypted key and the provider base URL.
    # ``get_decrypted_key`` raises MissingAIKey on absent / null rows; the
    # route layer maps that to HTTP 412 (Requirement 4.7).
    ai_key = settings_service.get_decrypted_key(user_id)
    settings_metadata = settings_service.get_settings(user_id)
    base_url = str(settings_metadata.ai_provider_base_url)

    # Step 1b: fetch real GitHub profile data to enrich the AI prompt.
    # Check if user has a stored GitHub token for richer data.
    github_data: dict = {}
    try:
        token_row = (
            sb.table("user_settings")
            .select("encrypted_github_token")
            .eq("user_id", str(user_id))
            .limit(1)
            .execute()
        )
        token_rows = token_row.data or []
        encrypted_token_value = (
            token_rows[0].get("encrypted_github_token") if token_rows else None
        )

        if encrypted_token_value:
            from app.core.encryption import get_encryption_service

            # Decode the bytea hex string
            if isinstance(encrypted_token_value, str) and encrypted_token_value.startswith("\\x"):
                token_bytes = bytes.fromhex(encrypted_token_value[2:])
            elif isinstance(encrypted_token_value, (bytes, bytearray)):
                token_bytes = bytes(encrypted_token_value)
            else:
                token_bytes = None

            if token_bytes:
                encryption = get_encryption_service()
                github_token = encryption.decrypt(token_bytes)
                github_data = await github_service.fetch_profile_with_token(github_token)
            else:
                github_data = await github_service.fetch_profile(str(request.github_url))
        else:
            github_data = await github_service.fetch_profile(str(request.github_url))
    except Exception:
        # Fall back to unauthenticated fetch on any error
        github_data = await github_service.fetch_profile(str(request.github_url))

    # Step 1c: fetch LinkedIn text from the user's profile if available.
    linkedin_text: str | None = None
    try:
        profile_resp = (
            sb.table("users")
            .select("linkedin_pdf_text")
            .eq("id", str(user_id))
            .limit(1)
            .execute()
        )
        rows = profile_resp.data or []
        if rows and rows[0].get("linkedin_pdf_text"):
            linkedin_text = rows[0]["linkedin_pdf_text"]
    except Exception:
        # Column may not exist yet; gracefully fall back to no text.
        pass

    # Step 2: call the AI provider. The plaintext key lives only inside
    # this stack frame and on the outbound Authorization header.
    envelope: AnalysisEnvelope = await ai_service.run(
        request,
        ai_key=ai_key,
        base_url=base_url,
        github_data=github_data,
        linkedin_text=linkedin_text,
    )

    # Step 3: insert exactly one row into analyses. We pre-mint the id and
    # created_at so the response carries identity even when PostgREST is
    # configured not to return inserted rows.
    new_id = uuid4()
    created_at_iso = _now_iso()
    sb.table(_ANALYSES_TABLE).insert(
        {
            "id": str(new_id),
            "user_id": str(user_id),
            "goal": request.goal,
            "github_url": str(request.github_url),
            "linkedin_url": str(request.linkedin_url),
            "result_json": _serialize_envelope(envelope),
            "created_at": created_at_iso,
        }
    ).execute()

    # Step 4a: upsert one row per skill_gap, deduplicating on (user_id, name).
    # Postgres applies the on-conflict clause per row, so repeated names
    # within the same payload collapse cleanly into a single row each.
    skill_rows = [
        {
            "user_id": str(user_id),
            "name": gap.name,
            "category": "General",
            "gap_level": gap.gap_level,
            "updated_at": created_at_iso,
        }
        for gap in envelope.skill_gaps
    ]
    if skill_rows:
        sb.table(_SKILLS_TABLE).upsert(
            skill_rows,
            on_conflict="user_id,name",
        ).execute()

    # Step 4b: upsert one row per suggestion, deduplicating on (user_id, title).
    roadmap_rows = [
        {
            "user_id": str(user_id),
            "title": suggestion.title,
            "description": suggestion.description,
            "priority": suggestion.priority,
            "updated_at": created_at_iso,
        }
        for suggestion in envelope.suggestions
    ]
    if roadmap_rows:
        sb.table(_ROADMAPS_TABLE).upsert(
            roadmap_rows,
            on_conflict="user_id,title",
        ).execute()

    # Hand back the full envelope plus persistence-side identifiers so the
    # client can link the in-memory response to the row it just persisted.
    return AnalysisResponse(
        id=new_id,
        created_at=datetime.fromisoformat(created_at_iso),
        **envelope.model_dump(),
    )


def get_latest(
    user_id: UUID,
    *,
    client: Client | None = None,
) -> AnalysisResponse | None:
    """Return the user's most recent analysis, or ``None`` if there are none.

    Selects ``analyses`` rows ordered by ``created_at`` descending and
    returns the first one, then reconstructs the public
    :class:`AnalysisResponse` shape from the row's ``result_json`` plus the
    row's ``id`` and ``created_at`` columns. Returns ``None`` when no rows
    exist so the route layer can render an HTTP 204 / empty-state Dashboard
    (Requirement 5.5).
    """
    sb = client if client is not None else get_supabase()

    response = (
        sb.table(_ANALYSES_TABLE)
        .select("id, created_at, result_json")
        .eq("user_id", str(user_id))
        .order("created_at", desc=True)
        .limit(1)
        .execute()
    )

    rows = response.data or []
    if not rows:
        return None

    row = rows[0]
    envelope_dict = row["result_json"]
    # ``result_json`` lands either as a dict (jsonb auto-decoded) or, in
    # tests against fakes, possibly as a JSON string. Handle both shapes.
    if isinstance(envelope_dict, str):
        import json as _json

        envelope_dict = _json.loads(envelope_dict)

    created_at_value = row["created_at"]
    if isinstance(created_at_value, str):
        created_at = datetime.fromisoformat(created_at_value)
    else:
        created_at = created_at_value

    return AnalysisResponse(
        id=UUID(str(row["id"])),
        created_at=created_at,
        **envelope_dict,
    )
