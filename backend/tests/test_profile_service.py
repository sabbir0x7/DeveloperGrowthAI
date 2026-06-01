"""Unit tests for :mod:`app.services.profile_service`.

The service layer talks to Supabase through the chained
``client.table(...).select/update.eq.execute`` builder pattern. Rather than
spin up a real Supabase project for unit tests, we feed in a tiny in-memory
double that records every chained call and returns canned ``data``. That
keeps the tests hermetic and fast while still exercising the exact builder
pattern the production service uses.

Coverage:

* ``get_profile`` returns a :class:`ProfileOut` matching the row.
* ``get_profile`` raises :class:`ProfileNotFound` on the PostgREST
  "no rows" error code.
* ``patch_profile`` only sends *explicitly-set* fields (PATCH semantics).
* ``patch_profile`` short-circuits to a read when the patch is empty so it
  never sends an empty ``UPDATE`` to PostgREST.
* ``patch_profile`` raises :class:`ProfileNotFound` when no row matches.
"""

from __future__ import annotations

from datetime import datetime, timezone
from typing import Any
from uuid import uuid4

import pytest
from postgrest.exceptions import APIError

from app.schemas.profile import ProfilePatch
from app.services.profile_service import (
    ProfileNotFound,
    get_profile,
    patch_profile,
)


# ---------------------------------------------------------------------------
# Test doubles
# ---------------------------------------------------------------------------


class _Response:
    """Minimal stand-in for postgrest's ``APIResponse``.

    The real object exposes ``data`` (the row(s)). That's all the service
    reads, so that's all this double provides.
    """

    def __init__(self, data: Any) -> None:
        self.data = data


class _SelectBuilder:
    """Records the chained calls and returns the canned response on execute()."""

    def __init__(
        self,
        recorder: dict[str, Any],
        response: _Response | Exception,
    ) -> None:
        self._recorder = recorder
        self._response = response

    def eq(self, column: str, value: Any) -> "_SelectBuilder":
        self._recorder["eq"] = (column, value)
        return self

    def single(self) -> "_SelectBuilder":
        self._recorder["single"] = True
        return self

    def execute(self) -> _Response:
        if isinstance(self._response, Exception):
            raise self._response
        return self._response


class _UpdateBuilder:
    """Records chained ``.update().eq().execute()`` calls."""

    def __init__(
        self,
        recorder: dict[str, Any],
        response: _Response | Exception,
    ) -> None:
        self._recorder = recorder
        self._response = response

    def eq(self, column: str, value: Any) -> "_UpdateBuilder":
        self._recorder["eq"] = (column, value)
        return self

    def execute(self) -> _Response:
        if isinstance(self._response, Exception):
            raise self._response
        return self._response


class _Table:
    """Captures one ``select`` and/or one ``update`` call per test."""

    def __init__(
        self,
        select_response: _Response | Exception | None = None,
        update_response: _Response | Exception | None = None,
    ) -> None:
        self.select_calls: list[dict[str, Any]] = []
        self.update_calls: list[dict[str, Any]] = []
        self._select_response = select_response
        self._update_response = update_response

    def select(self, columns: str) -> _SelectBuilder:
        record: dict[str, Any] = {"columns": columns}
        self.select_calls.append(record)
        # The service either calls .single() or not; default to a select with
        # data list so a fallback "read after empty patch" path also works.
        return _SelectBuilder(record, self._select_response or _Response([]))

    def update(self, payload: dict[str, Any]) -> _UpdateBuilder:
        record: dict[str, Any] = {"payload": payload}
        self.update_calls.append(record)
        return _UpdateBuilder(record, self._update_response or _Response([]))


class _Client:
    """Top-level Supabase client double - just dispatches to one table."""

    def __init__(self, table: _Table) -> None:
        self._table = table
        self.requested_tables: list[str] = []

    def table(self, name: str) -> _Table:
        self.requested_tables.append(name)
        return self._table


def _row(**overrides: Any) -> dict[str, Any]:
    """Build a complete ``users`` row dict for ProfileOut.model_validate."""
    base = {
        "id": str(uuid4()),
        "email": "user@example.com",
        "full_name": "Test User",
        "github_url": "https://github.com/example",
        "linkedin_url": "https://linkedin.com/in/example",
        "goal": "Become a Senior Backend Engineer",
        "created_at": datetime.now(tz=timezone.utc).isoformat(),
    }
    base.update(overrides)
    return base


# ---------------------------------------------------------------------------
# get_profile
# ---------------------------------------------------------------------------


def test_get_profile_returns_profile_out_for_existing_user() -> None:
    """A row that exists is mapped to ProfileOut through model_validate."""
    user_id = uuid4()
    row = _row(id=str(user_id))
    table = _Table(select_response=_Response(row))
    client = _Client(table)

    profile = get_profile(user_id, client=client)  # type: ignore[arg-type]

    # Round-trip the boundary type, then check fields. Confirms both the
    # return shape and the chained query: select(cols).eq("id", uid).single().
    assert profile.id == user_id
    assert profile.email == "user@example.com"
    assert client.requested_tables == ["users"]
    select_call = table.select_calls[0]
    assert "id" in select_call["columns"] and "email" in select_call["columns"]
    assert select_call["eq"] == ("id", str(user_id))
    assert select_call.get("single") is True


def test_get_profile_raises_profile_not_found_on_pgrst_no_row() -> None:
    """PostgREST's "no rows" code (PGRST116) maps to ProfileNotFound."""
    user_id = uuid4()
    api_error = APIError({"code": "PGRST116", "message": "no row"})
    table = _Table(select_response=api_error)
    client = _Client(table)

    with pytest.raises(ProfileNotFound):
        get_profile(user_id, client=client)  # type: ignore[arg-type]


def test_get_profile_re_raises_unexpected_api_error() -> None:
    """Any non-PGRST116 APIError is *not* swallowed - it propagates."""
    user_id = uuid4()
    api_error = APIError({"code": "PGRST500", "message": "internal"})
    table = _Table(select_response=api_error)
    client = _Client(table)

    with pytest.raises(APIError):
        get_profile(user_id, client=client)  # type: ignore[arg-type]


# ---------------------------------------------------------------------------
# patch_profile
# ---------------------------------------------------------------------------


def test_patch_profile_sends_only_explicitly_set_fields() -> None:
    """Pydantic ``exclude_unset`` semantics: omitted fields don't reach SQL."""
    user_id = uuid4()
    updated = _row(id=str(user_id), goal="Be a Staff Engineer")
    table = _Table(
        update_response=_Response([updated]),
        select_response=_Response(updated),
    )
    client = _Client(table)

    # Only ``goal`` is set. github_url and linkedin_url should NOT appear in
    # the update payload (PATCH semantics: omitted means "leave alone").
    patch = ProfilePatch.model_validate({"goal": "Be a Staff Engineer"})

    result = patch_profile(user_id, patch, client=client)  # type: ignore[arg-type]

    assert result.goal == "Be a Staff Engineer"
    assert len(table.update_calls) == 1
    payload = table.update_calls[0]["payload"]
    assert payload == {"goal": "Be a Staff Engineer"}
    assert "github_url" not in payload
    assert "linkedin_url" not in payload
    assert table.update_calls[0]["eq"] == ("id", str(user_id))


def test_patch_profile_serializes_url_fields_as_strings() -> None:
    """HttpUrl values are serialized to plain strings for the ``text`` column."""
    user_id = uuid4()
    new_github = "https://github.com/new-handle"
    updated = _row(id=str(user_id), github_url=new_github)
    table = _Table(
        update_response=_Response([updated]),
        select_response=_Response(updated),
    )
    client = _Client(table)

    patch = ProfilePatch.model_validate({"github_url": new_github})

    result = patch_profile(user_id, patch, client=client)  # type: ignore[arg-type]

    assert str(result.github_url).rstrip("/") == new_github.rstrip("/")
    payload = table.update_calls[0]["payload"]
    # HttpUrl-as-string lands as a plain string, not a Url object.
    assert isinstance(payload["github_url"], str)
    assert payload["github_url"].startswith("https://github.com/new-handle")


def test_patch_profile_with_empty_body_short_circuits_to_get() -> None:
    """An empty patch must not issue an empty UPDATE to PostgREST."""
    user_id = uuid4()
    row = _row(id=str(user_id))
    # No update_response needed; we expect zero update calls.
    table = _Table(select_response=_Response(row))
    client = _Client(table)

    patch = ProfilePatch()  # all fields unset

    result = patch_profile(user_id, patch, client=client)  # type: ignore[arg-type]

    assert result.id == user_id
    assert table.update_calls == []  # no UPDATE was sent
    assert len(table.select_calls) == 1  # but a read happened


def test_patch_profile_raises_profile_not_found_when_no_row_matches() -> None:
    """An update returning empty ``data`` means no row matched - 404 territory."""
    user_id = uuid4()
    table = _Table(
        update_response=_Response([]),
        select_response=_Response(_row(id=str(user_id))),
    )
    client = _Client(table)

    patch = ProfilePatch.model_validate({"goal": "Anything"})

    with pytest.raises(ProfileNotFound):
        patch_profile(user_id, patch, client=client)  # type: ignore[arg-type]
