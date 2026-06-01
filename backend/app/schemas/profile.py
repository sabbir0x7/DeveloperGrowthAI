"""Schemas for ``/api/v1/profile/me``.

Two shapes:

* :class:`ProfileOut` is what we hand back to the client on ``GET`` and on a
  successful ``PATCH``.
* :class:`ProfilePatch` is what the client sends on ``PATCH``. Every field is
  optional so partial updates work; the route handler treats unset fields as
  "leave alone" and explicit ``None`` as "the field was omitted from the
  request body" (Pydantic v2 distinguishes these via ``model_dump
  (exclude_unset=True)``).

Per the spec we additionally enforce HTTPS on ``github_url`` and
``linkedin_url``: ``HttpUrl`` alone would accept ``http://`` URLs, which is
forbidden by Requirements 2.4 and 6.7.
"""

from __future__ import annotations

from datetime import datetime
from uuid import UUID

from pydantic import BaseModel, EmailStr, Field, HttpUrl, field_validator

from app.schemas._validators import require_https


class ProfileOut(BaseModel):
    """The authenticated user's profile as returned by the API."""

    id: UUID
    email: EmailStr
    full_name: str | None
    github_url: HttpUrl | None
    linkedin_url: HttpUrl | None
    goal: str | None
    linkedin_pdf_text: str | None = None
    created_at: datetime


class ProfilePatch(BaseModel):
    """Partial update body for ``PATCH /profile/me``.

    ``goal`` is constrained at the schema layer so the service never has to
    re-check length: 1..500 characters mirrors Requirement 3.3 and the
    ``users.goal`` column constraint.

    ``linkedin_pdf_text`` allows the user to paste their LinkedIn
    summary/experience text for richer AI analysis. Stored in the
    ``users.linkedin_pdf_text`` column (requires migration).
    """

    github_url: HttpUrl | None = None
    linkedin_url: HttpUrl | None = None
    goal: str | None = Field(default=None, min_length=1, max_length=500)
    linkedin_pdf_text: str | None = Field(default=None, max_length=10000)

    @field_validator("github_url", "linkedin_url", mode="after")
    @classmethod
    def _enforce_https(cls, value: HttpUrl | None) -> HttpUrl | None:
        # Delegating to the shared helper keeps the ``http://`` rejection rule
        # identical across every URL field in the API surface.
        return require_https(value)
