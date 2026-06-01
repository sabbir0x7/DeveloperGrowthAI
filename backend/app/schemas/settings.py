"""Schemas for ``/api/v1/profile/settings``.

The settings endpoint deliberately splits read and write shapes:

* :class:`SettingsIn` carries the AI key on the way in. The service encrypts
  it before persisting (see :mod:`app.services.settings_service`).
* :class:`SettingsOut` carries only metadata on the way out -
  ``has_ai_key`` and ``ai_provider_base_url`` - so the decrypted key never
  rides on a response. This split is what makes Requirement 6.5 ("the
  decrypted AI key never appears in any response body") enforceable at the
  type system layer rather than relying on every handler to remember to
  redact.
"""

from __future__ import annotations

from pydantic import BaseModel, Field, HttpUrl, field_validator

from app.schemas._validators import require_https


class SettingsOut(BaseModel):
    """Settings metadata visible to the client."""

    has_ai_key: bool
    ai_provider_base_url: HttpUrl

    @field_validator("ai_provider_base_url", mode="after")
    @classmethod
    def _enforce_https(cls, value: HttpUrl) -> HttpUrl:
        return require_https(value)


class SettingsIn(BaseModel):
    """Body for ``PUT /profile/settings``.

    ``ai_key`` has a sane lower bound (``min_length=8``) so empty strings and
    obvious typos are rejected at the boundary instead of being encrypted and
    stored. The value is never logged and is dropped from memory once the
    service has handed off to :class:`~app.core.encryption.EncryptionService`.
    """

    ai_key: str = Field(min_length=8)
    ai_provider_base_url: HttpUrl

    @field_validator("ai_provider_base_url", mode="after")
    @classmethod
    def _enforce_https(cls, value: HttpUrl) -> HttpUrl:
        # Requirement 6.7: HTTP base URLs must yield 422.
        return require_https(value)
