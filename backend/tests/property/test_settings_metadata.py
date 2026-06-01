"""Property test: GET /profile/settings exposes only metadata.

Validates **Property 18** (design.md): for any settings row, the API
representation returns a body whose keys are exactly
``{has_ai_key, ai_provider_base_url}`` and never contains the AI key in any
form.

Validates **Requirement 6.6**:

    "WHEN the Frontend_App requests the user's settings, THE
     Settings_Service SHALL return a boolean ``has_ai_key`` flag and the
     Provider_Base_URL but SHALL NOT return the AI_Key."

The property is exercised at the service-layer boundary (the only place an
AI key transits between the encrypted column and a Pydantic response):
:func:`app.services.settings_service.get_settings` is invoked against an
in-memory Supabase double that has been seeded with a Hypothesis-generated
key. The test asserts:

* The returned :class:`SettingsOut` has exactly two fields.
* The serialized JSON form contains exactly those two keys.
* Neither the original key nor any prefix/substring of length >= 8 of it
  appears anywhere in the serialized response.

The substring check guards against the kind of accidental leak that would
*also* serialize part of the encrypted ciphertext or the raw column value,
so this property doubles as a regression check on the service's encoding
boundary.
"""

from __future__ import annotations

import json
import secrets
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any
from uuid import uuid4

import pytest
from cryptography.fernet import Fernet
from hypothesis import HealthCheck, given, settings as h_settings, strategies as st


# A single Fernet key per process is enough; encryption is deterministic
# enough across the property body and the round-trip test in
# `test_encryption_roundtrip.py` already covers the cipher-level invariants.
_FERNET_KEY = Fernet.generate_key().decode("utf-8")


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Provide the env required by `Settings` and reset cached singletons."""
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
# Supabase double (mirrors the chained builder used by settings_service).
# ---------------------------------------------------------------------------


@dataclass
class _ExecuteResult:
    data: list[dict[str, Any]]


@dataclass
class _FakeQuery:
    rows: list[dict[str, Any]]

    def select(self, _columns: str) -> "_FakeQuery":
        return self

    def eq(self, _column: str, _value: Any) -> "_FakeQuery":
        return self

    def limit(self, _n: int) -> "_FakeQuery":
        return self

    def execute(self) -> _ExecuteResult:
        return _ExecuteResult(data=list(self.rows))


@dataclass
class _FakeTable:
    rows: list[dict[str, Any]] = field(default_factory=list)

    def select(self, columns: str) -> _FakeQuery:
        return _FakeQuery(rows=self.rows)


class _FakeSupabase:
    def __init__(self, rows: list[dict[str, Any]]) -> None:
        self._table = _FakeTable(rows=rows)

    def table(self, _name: str) -> _FakeTable:
        return self._table


# ---------------------------------------------------------------------------
# Property body
# ---------------------------------------------------------------------------


_settings_out_keys = {"has_ai_key", "ai_provider_base_url"}

# AI keys live behind the SettingsIn(min_length=8) bound; we mirror that
# domain for the generator so substrings of length >= 8 are meaningful.
_ai_key_strategy = st.text(min_size=8, max_size=128).filter(lambda s: len(s) > 0)


@h_settings(
    max_examples=50,
    suppress_health_check=[HealthCheck.function_scoped_fixture],
    deadline=None,
)
@given(plaintext=_ai_key_strategy)
def test_settings_out_exposes_only_metadata_and_never_the_key(
    monkeypatch: pytest.MonkeyPatch,
    plaintext: str,
) -> None:
    """Validates Requirement 6.6 / Property 18.

    For an arbitrary AI key ``plaintext``:

    1. Encrypt and seed it into the fake `user_settings` row.
    2. Call `get_settings(user_id)` through the service.
    3. Assert the returned `SettingsOut` exposes exactly two fields.
    4. Serialize the response to JSON; assert the same two keys.
    5. Assert the plaintext is *not* a substring of the serialized response.
    """
    # Late imports keep the env fixture in control of cache state.
    from app.core.encryption import get_encryption_service
    from app.services import settings_service
    from app.services.settings_service import get_settings

    ciphertext = get_encryption_service().encrypt(plaintext)
    rows = [
        {
            "encrypted_ai_key": "\\x" + ciphertext.hex(),
            "ai_provider_base_url": "https://api.openai.com/v1",
        }
    ]
    fake_client = _FakeSupabase(rows=rows)
    monkeypatch.setattr(settings_service, "get_supabase", lambda: fake_client)

    out = get_settings(uuid4())

    # 1. Pydantic model only exposes the metadata fields.
    assert set(out.model_fields.keys()) == _settings_out_keys

    # 2. Serialized JSON has exactly those keys, nothing else.
    serialized = out.model_dump_json()
    decoded = json.loads(serialized)
    assert set(decoded.keys()) == _settings_out_keys

    # 3. has_ai_key is correctly derived from the seeded ciphertext.
    assert decoded["has_ai_key"] is True

    # 4. The plaintext key is never present in any form in the response.
    assert plaintext not in serialized
    # And not in the dict-rendered form either (defensive against future
    # custom serializers).
    assert plaintext not in repr(decoded)
