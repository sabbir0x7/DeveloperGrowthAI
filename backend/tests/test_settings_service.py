"""Unit tests for `services/settings_service.py`.

These tests validate the service's three public entry points end-to-end
*through* the real :class:`EncryptionService` while stubbing the Supabase
client. They cover:

* :func:`get_settings` returns metadata only - never the plaintext key,
  even when a ciphertext exists. Maps to Requirements 6.5 / 6.6.
* :func:`put_settings` encrypts the key with the configured Fernet keys
  before writing, and never returns the plaintext on the response shape.
  Maps to Requirements 6.1, 6.2, 6.3.
* :func:`get_decrypted_key` round-trips ciphertext back to plaintext for
  the analysis service, and raises :class:`MissingAIKey` for both
  ``no row`` and ``null column`` shapes (Requirement 4.7).

Property-based round-trip coverage of :class:`EncryptionService` lives in
``tests/property/test_encryption_roundtrip.py`` (Property 16). These
example tests focus on the service contract layered on top.
"""

from __future__ import annotations

import secrets
from collections.abc import Iterator
from dataclasses import dataclass, field
from typing import Any
from uuid import uuid4

import pytest
from cryptography.fernet import Fernet


# ---------------------------------------------------------------------------
# Env + cache fixtures
# ---------------------------------------------------------------------------


# A single in-test Fernet key keeps encryption deterministic enough for
# the assertions below while still exercising the real cipher.
_FERNET_KEY = Fernet.generate_key().decode("utf-8")


@pytest.fixture(autouse=True)
def _env(monkeypatch: pytest.MonkeyPatch) -> Iterator[None]:
    """Provide the env required by `Settings` and reset cached singletons."""
    monkeypatch.setenv("SUPABASE_URL", "https://example.supabase.co")
    monkeypatch.setenv("SUPABASE_SERVICE_ROLE_KEY", "service-role-placeholder")
    monkeypatch.setenv("SUPABASE_JWT_SECRET", "test-secret-" + secrets.token_urlsafe(8))
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
# Supabase client double
#
# We mimic the chain `client.table(...).select(...).eq(...).limit(...).execute()`
# and `.upsert(...).execute()`, capturing the calls so tests can assert what
# the service sent. Only the methods exercised by `settings_service` are
# implemented - anything else raises immediately.
# ---------------------------------------------------------------------------


@dataclass
class _ExecuteResult:
    data: list[dict[str, Any]]


@dataclass
class _FakeQuery:
    """Captures select + filter calls and returns a stubbed payload."""

    rows: list[dict[str, Any]]
    selected_columns: str | None = None
    filters: list[tuple[str, Any]] = field(default_factory=list)
    limited: int | None = None

    def select(self, columns: str) -> "_FakeQuery":
        self.selected_columns = columns
        return self

    def eq(self, column: str, value: Any) -> "_FakeQuery":
        self.filters.append((column, value))
        return self

    def limit(self, n: int) -> "_FakeQuery":
        self.limited = n
        return self

    def execute(self) -> _ExecuteResult:
        return _ExecuteResult(data=list(self.rows))


@dataclass
class _FakeUpsert:
    """Captures upsert payloads."""

    payloads: list[dict[str, Any]]
    on_conflicts: list[str | None] = field(default_factory=list)

    def execute(self) -> _ExecuteResult:
        return _ExecuteResult(data=[])


@dataclass
class _FakeTable:
    """Captures upsert payloads and dispatches selects to a fresh _FakeQuery."""

    rows: list[dict[str, Any]]
    select_calls: list[_FakeQuery] = field(default_factory=list)
    upsert_calls: list[dict[str, Any]] = field(default_factory=list)
    last_on_conflict: str | None = None

    def select(self, columns: str) -> _FakeQuery:
        q = _FakeQuery(rows=self.rows)
        self.select_calls.append(q)
        return q.select(columns)

    def upsert(
        self, payload: dict[str, Any], *, on_conflict: str | None = None
    ) -> _FakeUpsert:
        self.upsert_calls.append(payload)
        self.last_on_conflict = on_conflict
        # Mirror the write into our row buffer so subsequent selects in the
        # same test see the new state.
        self.rows.clear()
        self.rows.append(
            {
                "encrypted_ai_key": payload.get("encrypted_ai_key"),
                "ai_provider_base_url": payload.get("ai_provider_base_url"),
            }
        )
        return _FakeUpsert(payloads=[payload])


@dataclass
class _FakeSupabase:
    """Top-level fake exposing `.table(name)` like the real client."""

    tables: dict[str, _FakeTable] = field(default_factory=dict)

    def table(self, name: str) -> _FakeTable:
        return self.tables.setdefault(name, _FakeTable(rows=[]))


@pytest.fixture
def fake_supabase(monkeypatch: pytest.MonkeyPatch) -> _FakeSupabase:
    """Patch `get_supabase` in the service module to return our fake."""
    fake = _FakeSupabase()
    from app.services import settings_service

    monkeypatch.setattr(settings_service, "get_supabase", lambda: fake)
    return fake


# ---------------------------------------------------------------------------
# get_settings
# ---------------------------------------------------------------------------


def test_get_settings_returns_default_when_row_absent(fake_supabase: _FakeSupabase) -> None:
    """No `user_settings` row -> `has_ai_key=False` and the default base URL."""
    from app.services.settings_service import get_settings

    out = get_settings(uuid4())

    assert out.has_ai_key is False
    assert str(out.ai_provider_base_url).startswith("https://api.openai.com/v1")


def test_get_settings_metadata_only_when_key_present(fake_supabase: _FakeSupabase) -> None:
    """Stored ciphertext flips `has_ai_key=True` but the key never appears in the response."""
    from app.core.encryption import get_encryption_service
    from app.services.settings_service import get_settings

    plaintext = "sk-test-" + secrets.token_urlsafe(32)
    ciphertext = get_encryption_service().encrypt(plaintext)
    user_id = uuid4()

    # Seed a row in the fake table using the bytea hex format the service expects.
    fake_supabase.tables.setdefault("user_settings", _FakeTable(rows=[])).rows.append(
        {
            "encrypted_ai_key": "\\x" + ciphertext.hex(),
            "ai_provider_base_url": "https://api.groq.com/openai/v1",
        }
    )

    out = get_settings(user_id)

    assert out.has_ai_key is True
    assert str(out.ai_provider_base_url) == "https://api.groq.com/openai/v1"

    # Property 18 reinforcement: serialized response carries no key material.
    serialized = out.model_dump_json()
    assert plaintext not in serialized


def test_get_settings_treats_null_column_as_no_key(fake_supabase: _FakeSupabase) -> None:
    """A row with a null `encrypted_ai_key` reads as `has_ai_key=False`."""
    from app.services.settings_service import get_settings

    fake_supabase.tables.setdefault("user_settings", _FakeTable(rows=[])).rows.append(
        {
            "encrypted_ai_key": None,
            "ai_provider_base_url": "https://api.openai.com/v1",
        }
    )

    out = get_settings(uuid4())

    assert out.has_ai_key is False


# ---------------------------------------------------------------------------
# put_settings
# ---------------------------------------------------------------------------


def test_put_settings_encrypts_before_write(fake_supabase: _FakeSupabase) -> None:
    """The stored bytea is Fernet ciphertext, not the plaintext key."""
    from app.schemas.settings import SettingsIn
    from app.services.settings_service import put_settings

    plaintext = "sk-live-" + secrets.token_urlsafe(40)
    payload = SettingsIn(ai_key=plaintext, ai_provider_base_url="https://api.openai.com/v1")

    out = put_settings(uuid4(), payload)

    table = fake_supabase.tables["user_settings"]
    assert len(table.upsert_calls) == 1
    written = table.upsert_calls[0]

    # Bytea is hex-encoded with the `\x` prefix.
    encoded = written["encrypted_ai_key"]
    assert isinstance(encoded, str) and encoded.startswith("\\x")
    raw = bytes.fromhex(encoded[2:])
    # The plaintext bytes must not appear anywhere in the ciphertext.
    assert plaintext.encode("utf-8") not in raw

    # Conflict target keeps the upsert idempotent per user.
    assert table.last_on_conflict == "user_id"

    # The response shape never carries the key.
    assert out.has_ai_key is True
    assert plaintext not in out.model_dump_json()


def test_put_settings_overwrites_existing_row(fake_supabase: _FakeSupabase) -> None:
    """Repeated `put_settings` calls upsert under the same `user_id` key."""
    from app.schemas.settings import SettingsIn
    from app.services.settings_service import put_settings

    user_id = uuid4()
    put_settings(
        user_id,
        SettingsIn(ai_key="sk-aaaaaaaa", ai_provider_base_url="https://api.openai.com/v1"),
    )
    put_settings(
        user_id,
        SettingsIn(ai_key="sk-bbbbbbbb", ai_provider_base_url="https://api.openai.com/v1"),
    )

    table = fake_supabase.tables["user_settings"]
    assert len(table.upsert_calls) == 2
    assert all(call["user_id"] == str(user_id) for call in table.upsert_calls)


# ---------------------------------------------------------------------------
# get_decrypted_key
# ---------------------------------------------------------------------------


def test_get_decrypted_key_round_trips(fake_supabase: _FakeSupabase) -> None:
    """Writing then reading returns the exact plaintext."""
    from app.schemas.settings import SettingsIn
    from app.services.settings_service import get_decrypted_key, put_settings

    plaintext = "sk-test-roundtrip-" + secrets.token_urlsafe(24)
    user_id = uuid4()
    put_settings(
        user_id,
        SettingsIn(ai_key=plaintext, ai_provider_base_url="https://api.openai.com/v1"),
    )

    assert get_decrypted_key(user_id) == plaintext


def test_get_decrypted_key_missing_row_raises(fake_supabase: _FakeSupabase) -> None:
    """Absent row maps to `MissingAIKey` so the route can return 412."""
    from app.services.settings_service import MissingAIKey, get_decrypted_key

    with pytest.raises(MissingAIKey):
        get_decrypted_key(uuid4())


def test_get_decrypted_key_null_column_raises(fake_supabase: _FakeSupabase) -> None:
    """A row with no key column raises `MissingAIKey` just like an absent row."""
    from app.services.settings_service import MissingAIKey, get_decrypted_key

    fake_supabase.tables.setdefault("user_settings", _FakeTable(rows=[])).rows.append(
        {
            "encrypted_ai_key": None,
            "ai_provider_base_url": "https://api.openai.com/v1",
        }
    )

    with pytest.raises(MissingAIKey):
        get_decrypted_key(uuid4())
