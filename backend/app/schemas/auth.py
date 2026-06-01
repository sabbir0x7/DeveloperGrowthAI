"""Schemas for ``/api/v1/auth`` endpoints.

Right now there is exactly one endpoint - ``POST /auth/verify-token`` - and it
echoes the authenticated identity back to the client. We mirror the shape of
:class:`app.core.security.CurrentUser` rather than serializing the dataclass
directly so that:

* the wire contract is owned by Pydantic (typed, documented, and enforced at
  the boundary), and
* internal fields like raw JWT claims never leak through the response by
  accident.
"""

from __future__ import annotations

from uuid import UUID

from pydantic import BaseModel, EmailStr


class VerifyTokenResponse(BaseModel):
    """Public shape of an authenticated identity returned by ``/auth/verify-token``.

    Mirrors the public-safe subset of :class:`~app.core.security.CurrentUser`:
    the user's UUID and (when present) their email address. ``email`` is
    optional because Supabase access tokens for non-email auth flows may omit
    the claim entirely.
    """

    id: UUID
    email: EmailStr | None = None
