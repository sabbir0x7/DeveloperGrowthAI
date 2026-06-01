"""Schemas for ``/api/v1/analysis/*``.

These types are the strict contract for both directions of the AI pipeline:

* :class:`AnalysisRequest` validates the request body the Flutter client
  sends to ``POST /analysis/run``.
* :class:`AnalysisEnvelope` is the structured payload the AI provider must
  return. The AI service parses ``choices[0].message.content`` against this
  model and retries once if validation fails (Requirement 4.6).
* :class:`AnalysisResponse` is what the API returns to the client - the
  envelope plus the persistence-added ``id`` and ``created_at`` columns
  pulled from the ``analyses`` table.

``SkillGap`` and ``Suggestion`` use ``Literal`` enums for their level/priority
fields so the AI cannot smuggle ad-hoc strings (e.g. ``"critical"``) into the
database; anything outside the allowed set fails envelope validation and
triggers the retry/502 path.
"""

from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, Field, HttpUrl, field_validator

from app.schemas._validators import require_https


class AnalysisRequest(BaseModel):
    """Inputs to a single analysis run.

    Mirrors the three writable fields on the user's profile but is sent on
    the request body rather than read from the database, so the client can
    trigger a what-if analysis without first persisting changes.
    """

    github_url: HttpUrl
    linkedin_url: HttpUrl
    goal: str = Field(min_length=1, max_length=500)

    @field_validator("github_url", "linkedin_url", mode="after")
    @classmethod
    def _enforce_https(cls, value: HttpUrl) -> HttpUrl:
        return require_https(value)


class SkillGap(BaseModel):
    """One identified skill gap returned by the AI.

    ``gap_level`` is constrained to a closed set so it can be persisted into
    ``skills.gap_level`` without a second round of validation downstream.
    """

    name: str
    gap_level: Literal["low", "medium", "high"]
    rationale: str


class Suggestion(BaseModel):
    """One suggested next step returned by the AI.

    Persisted into the ``roadmaps`` table; ``priority`` mirrors the
    ``roadmaps.priority`` column constraint. ``timeline`` and ``steps``
    provide a week-by-week action plan.
    """

    title: str
    description: str
    priority: Literal["low", "medium", "high"]
    timeline: str = ""
    steps: list[str] = []


class AnalysisEnvelope(BaseModel):
    """The strict JSON shape the AI provider must return.

    ``github_analysis`` and ``linkedin_analysis`` are intentionally typed as
    ``dict`` rather than a more specific model: their internal shape is free-
    form analysis text that the frontend renders as glassmorphism cards, and
    we do not want to reject otherwise-valid analyses just because the AI
    chose a different sub-key layout. The list-typed fields, in contrast,
    feed structured persistence (skills/roadmaps tables) and so are tightly
    typed.
    """

    github_analysis: dict
    linkedin_analysis: dict
    skill_gaps: list[SkillGap]
    suggestions: list[Suggestion]


class AnalysisResponse(AnalysisEnvelope):
    """API response shape for ``POST /analysis/run`` and ``GET /analysis/latest``.

    Inherits every field of :class:`AnalysisEnvelope` and adds the
    persistence-side columns assigned when the row is written to ``analyses``.
    Subclassing (rather than composition) keeps the JSON shape identical to
    the envelope for clients that already know how to render the envelope.
    """

    id: UUID
    created_at: datetime
