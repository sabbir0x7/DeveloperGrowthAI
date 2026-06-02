"""Profile read/write service.

Backed by the service-role Supabase client because RLS is bypassed by the
service role; the *service* layer is responsible for scoping every query to
the authenticated user via an explicit ``id = user_id`` filter. This module
is the single chokepoint for that scoping on the ``users`` table.

Reads, partial updates, and conversion between the database row shape and
the :class:`~app.schemas.profile.ProfileOut` boundary type all live here so
the route handlers in :mod:`app.api.v1.profile` stay thin.

First-login row creation is handled by the ``handle_new_user`` Postgres
trigger (migration 0003); this service therefore assumes a row exists for
every authenticated user and surfaces :class:`ProfileNotFound` only as a
defensive fallback.

Requirements covered: 2.1, 2.2, 2.3, 2.5.
"""

from __future__ import annotations

from typing import Any
from uuid import UUID

from postgrest.exceptions import APIError
from supabase import Client

from app.core.supabase_client import get_supabase
from app.schemas.profile import ProfileOut, ProfilePatch

# Columns we project for every ProfileOut response. Listed explicitly (rather
# than ``select("*")``) so accidental schema additions cannot leak through the
# API surface without a deliberate change here.
_PROFILE_COLUMNS = "id, email, full_name, github_url, linkedin_url, goal, linkedin_pdf_text, created_at"

# PostgREST's error code for "single object filter returned 0 (or >1) rows".
# We translate it to a domain-level :class:`ProfileNotFound` so the route
# layer can map it to HTTP 404 without importing PostgREST internals.
_PGRST_NO_ROW_CODE = "PGRST116"


class ProfileNotFound(Exception):
    """Raised when no ``users`` row exists for the authenticated caller.

    The ``handle_new_user`` trigger should make this unreachable in normal
    operation (every Supabase signup mirrors a row into ``public.users``),
    so the API layer treats it as a defensive 404 rather than a normal flow.
    """


def get_profile(user_id: UUID, *, client: Client | None = None) -> ProfileOut:
    """Return the ``users`` row for ``user_id`` as a :class:`ProfileOut`.

    The optional ``client`` keyword exists so tests can inject a Supabase
    double; production callers omit it and pick up the singleton.

    Raises:
        ProfileNotFound: if no row matches ``user_id``.
    """
    sb = client if client is not None else get_supabase()
    try:
        response = (
            sb.table("users")
            .select(_PROFILE_COLUMNS)
            .eq("id", str(user_id))
            .single()
            .execute()
        )
    except APIError as exc:
        # ``single()`` raises an APIError with code ``PGRST116`` when zero
        # rows match the filter. Any other code is an unexpected upstream
        # failure and re-surfaces unchanged so it can be observed in logs.
        if exc.code == _PGRST_NO_ROW_CODE:
            raise ProfileNotFound(str(user_id)) from exc
        raise

    return _row_to_profile(response.data)


def patch_profile(
    user_id: UUID,
    patch: ProfilePatch,
    *,
    client: Client | None = None,
) -> ProfileOut:
    """Apply a partial update to ``users[id = user_id]`` and return the new row.

    Only fields the client explicitly set on ``patch`` are included in the
    SQL ``UPDATE`` (via Pydantic v2's ``model_dump(exclude_unset=True)``).
    That mirrors HTTP ``PATCH`` semantics: omitted keys mean "leave alone",
    while an explicit ``null`` clears the column. Schema-level constraints
    on ``ProfilePatch`` (HTTPS-only URLs, goal length 1..500) have already
    fired before we ever reach this function, so the service layer never
    re-validates input shape.

    An empty patch (no fields set) is treated as a read-only no-op; we issue
    a ``GET`` rather than a malformed empty ``UPDATE`` against PostgREST.

    Raises:
        ProfileNotFound: if no row matches ``user_id``.
    """
    sb = client if client is not None else get_supabase()
    update_data = _serialize_patch(patch)

    if not update_data:
        # Nothing to write - just return the current row. PostgREST rejects
        # empty UPDATE bodies, so guarding here keeps the service contract
        # ("PATCH always yields the current state") intact.
        return get_profile(user_id, client=sb)

    response = (
        sb.table("users")
        .update(update_data)
        .eq("id", str(user_id))
        .execute()
    )

    rows = response.data or []
    if not rows:
        # No row matched the id filter. Normally unreachable thanks to the
        # handle_new_user trigger, but we still translate it to the domain
        # exception so the API layer can return 404.
        raise ProfileNotFound(str(user_id))

    # The update response may not include all columns (PostgREST only
    # returns the columns that were part of the update payload). Do a
    # full read to ensure the caller gets the complete profile.
    return get_profile(user_id, client=sb)


def _row_to_profile(row: dict[str, Any]) -> ProfileOut:
    """Map a raw ``users`` row dict to the :class:`ProfileOut` boundary type.

    Pydantic v2 handles UUID/str and ``timestamptz``/``datetime`` coercion
    on its own, so we just hand the dict over.
    """
    return ProfileOut.model_validate(row)


def _serialize_patch(patch: ProfilePatch) -> dict[str, Any]:
    """Convert a :class:`ProfilePatch` into the column dict PostgREST accepts.

    ``exclude_unset=True`` keeps only fields the client actually sent, which
    is what makes ``PATCH`` semantics work. ``mode="json"`` coerces Pydantic
    URL types into plain strings so they fit the ``text`` columns on the
    ``users`` table without an extra round of manual stringification.
    """
    return patch.model_dump(exclude_unset=True, mode="json")


def delete_profile(user_id: UUID | str, *, client: Client | None = None) -> None:
    """Delete the user from Supabase Auth (cascades to public tables)."""
    sb = client if client is not None else get_supabase()
    sb.auth.admin.delete_user(str(user_id))


__all__ = ["ProfileNotFound", "get_profile", "patch_profile", "delete_profile"]
